#!/usr/bin/env bash
# =============================================================================
# setup-arduino-q-mic-applab.sh — for arduino-app-cli 0.9.0+ firmware bundle
#
# Reproducible setup for the analog microphone on Arduino UNO Q
# with Arduino Lab / Arduino App CLI (UNO Q EchoGlow).
#
# Usage:
#   chmod +x setup-arduino-q-mic-applab.sh
#   sudo ./setup-arduino-q-mic-applab.sh
#
# Safe to run multiple times (idempotent).
#
# What this script does:
#   1. ALSA mixer init script + mic-uno-q.service (one-shot, applies the 9
#      mixer controls at boot so arecord on the host works immediately).
#      Apps must re-apply the mixer per PCM open (see uno-q-echoglow/python
#      /main.py for the subclass pattern that does this) because WirePlumber
#      flips the MultiMedia3 routing mixer off after the boot service runs.
#      /etc/asound.conf must NOT exist on the host — any content there breaks
#      PCM open inside app containers. If a file is present from a previous
#      setup, it is backed up and removed.
#   2. /dev/snd/by-id symlink + udev rule. arduino-app-cli's deploy validator
#      requires a USB-like ALSA device under /dev/snd/by-id/usb-* for apps
#      that use the keyword_spotting brick, so we expose the analog codec
#      under a fake usb-* symlink. Persisted via udev rule.
#   3. Deploy UNO Q EchoGlow example to the arduino-app-cli examples dir,
#      under inspirational/platform_unoq/ (App Lab 0.10+ category layout).
#   4. Patch arduino:zephyr 0.55.0 gpio_lowlevel_stm32.h regression that
#      breaks Adafruit_BusIO 1.16.1 (macro takes a pin instead of a port).
#
# Apps that use the keyword_spotting brick must pass an explicit device to
# avoid the default `usb:1` (which fails — the codec is on SoC, not USB):
#   mic = Microphone(device="plughw:CARD=ArduinoImolaHPH,DEV=2", shared=False)
#   spotter = KeywordSpotting(mic=mic)
# See Software/uno-q-echoglow/python/main.py for the reference pattern.
#
# Compatible firmware bundle:
#   - arduino-app-cli 0.9.0+ (Docker image python-apps-base:0.9.0+)
#   - arduino:zephyr 0.55.0
#   - PipeWire 1.4.2 / WirePlumber 0.5.8
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment variables if needed
# ---------------------------------------------------------------------------

# Auto-detect arduino-app-cli version from assets directory
# Checks both /var/lib and ~/.local/share locations.
# Uses find -printf instead of `ls | sort` for whitespace/locale safety.
_detect_version() {
  local v
  for base in /var/lib/arduino-app-cli ~/.local/share/arduino-app-cli; do
    if [ -d "${base}/assets" ]; then
      v=$(find "${base}/assets" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null \
            | sort -V | tail -1)
      [ -n "$v" ] && echo "$v" && return
    fi
  done
  echo "0.9.0"  # sane fallback for new boards if assets dir is not enumerated yet
}

APP_CLI_VERSION="${APP_CLI_VERSION:-$(_detect_version)}"
DOCKER_IMAGE="ghcr.io/arduino/app-bricks/python-apps-base:${APP_CLI_VERSION}"
UDEV_RULE="/etc/udev/rules.d/99-arduino-uno-q-mic.rules"
ASOUND_CONF="/etc/asound.conf"
STAMP_DIR="/var/lib/arduino-uno-q-setup"
STAMP_ALSA="${STAMP_DIR}/alsa_setup_done"
STAMP_UDEV="${STAMP_DIR}/udev_setup_done"
STAMP_ZEPHYR="${STAMP_DIR}/zephyr_gpio_done"

# Examples dir — check both /var/lib and ~/.local/share
_detect_examples_dir() {
  for base in /var/lib/arduino-app-cli ~/.local/share/arduino-app-cli; do
    [ -d "${base}/examples" ] && echo "${base}/examples" && return
  done
  echo "/var/lib/arduino-app-cli/examples"  # fallback
}

# Colors
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; BLUE=''; NC=''
fi

info()    { printf "${BLUE}[INFO]${NC}  %s\n" "$*"; }
ok()      { printf "${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()    { printf "${YELLOW}[WARN]${NC}  %s\n" "$*"; }
fail()    { printf "${RED}[FAIL]${NC}  %s\n" "$*" >&2; exit 1; }
skipped() { printf "${YELLOW}[SKIP]${NC}  %s\n" "$*"; }

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
preflight_checks() {
  info "Running preflight checks..."
  [ "$(id -u)" -eq 0 ] || fail "Run as root: sudo $0"
  for cmd in python3 docker amixer arecord systemctl udevadm; do
    command -v "$cmd" >/dev/null 2>&1 || fail "Required command not found: $cmd"
  done
  # Wait briefly for the ALSA driver to enumerate the codec on fresh boots
  local i
  for i in $(seq 1 5); do
    aplay -l 2>/dev/null | grep -q "ArduinoImolaHPH" && break
    sleep 2
  done
  if ! aplay -l 2>/dev/null | grep -q "ArduinoImolaHPH"; then
    # Check whether the audio driver chain is stuck in deferred probe — a known
    # post-factory-reset state where qcom-sm6115-lpass-lpi-pinctrl can't acquire
    # the 'audio' clock, blocking the whole codec/soundwire/sound stack.
    local stuck=0
    if dmesg 2>/dev/null | grep -qE "lpass.*Failed to get clk 'audio'|sound: deferred probe pending"; then
      stuck=1
    fi
    echo "" >&2
    printf "${RED}[FAIL]${NC}  ArduinoImolaHPH codec not detected.\n" >&2
    echo "" >&2
    if [ "$stuck" -eq 1 ]; then
      echo "        The LPASS audio driver chain is stuck in deferred probe — a" >&2
      echo "        known state after factory reset where a plain reboot does NOT" >&2
      echo "        clear it. Power-cycle the board:" >&2
      echo "" >&2
      echo "          1. Disconnect the power cable" >&2
      echo "          2. Wait ~5 seconds" >&2
      echo "          3. Reconnect power and wait ~30 s for boot" >&2
      echo "          4. Re-run this script" >&2
      echo "" >&2
      echo "        Verify with:  arecord -l | grep ArduinoImolaHPH" >&2
    else
      echo "        Wait a few seconds for the ALSA driver to enumerate the codec" >&2
      echo "        and re-run this script. Verify with:" >&2
      echo "          arecord -l | grep ArduinoImolaHPH" >&2
      echo "" >&2
      echo "        If the codec never appears, power-cycle the board" >&2
      echo "        (disconnect and reconnect power, not just reboot)." >&2
    fi
    echo "" >&2
    exit 1
  fi
  mkdir -p "${STAMP_DIR}"
  ok "Preflight OK."
}

# ---------------------------------------------------------------------------
# Step 1 — ALSA mixer init + mic-uno-q.service + remove /etc/asound.conf
# ---------------------------------------------------------------------------
setup_alsa() {
  if [ -f "${STAMP_ALSA}" ]; then
    skipped "ALSA already configured."; return
  fi
  info "Step 1: ALSA mixer init + mic-uno-q.service..."

  # Mixer initialization happens via mic-uno-q-init.sh (written below) and is
  # invoked at boot by mic-uno-q.service. We do NOT run amixer here directly:
  # `systemctl enable --now` below starts the service immediately, which runs
  # the init script with correct quoting for the control names that contain
  # spaces (a previous in-script loop hit bash word-splitting on those).

  # /etc/asound.conf must NOT exist. ANY content there — even a minimal
  # `pcm.arduino_mic` alias — breaks PCM open inside app containers. If a
  # file is present we back it up and remove it; if absent we move on.
  # Apps must pass an explicit ALSA device:
  #   Microphone(device="plughw:CARD=ArduinoImolaHPH,DEV=2", shared=False)
  if [ -f "${ASOUND_CONF}" ]; then
    cp -a "${ASOUND_CONF}" "${ASOUND_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
    rm -f "${ASOUND_CONF}"
    ok "Removed pre-existing ${ASOUND_CONF} (backup kept)"
  else
    ok "${ASOUND_CONF} absent (correct state)"
  fi

  # Boot-time init script — runs amixer after the ALSA driver loads
  cat > /usr/local/bin/mic-uno-q-init.sh << 'EOF'
#!/bin/bash
# Wait up to 30s for the ALSA driver to enumerate the codec
found=0
for i in $(seq 1 15); do
    if arecord -l 2>/dev/null | grep -q "ArduinoImolaHPH"; then
        found=1
        break
    fi
    sleep 2
done
if [ "$found" -eq 0 ]; then
    logger -p user.warning "mic-uno-q: ArduinoImolaHPH not detected after 30s; mixer init may not stick"
fi
amixer -c 0 cset name='TX DEC0 MUX'                         'SWR_MIC'  >/dev/null 2>&1
amixer -c 0 cset name='TX SMIC MUX0'                        'SWR_MIC1' >/dev/null 2>&1
amixer -c 0 cset name='ADC2 MUX'                            'INP2'     >/dev/null 2>&1
amixer -c 0 cset name='ADC2 Switch'                          1          >/dev/null 2>&1
amixer -c 0 cset name='ADC2 Volume'                          8          >/dev/null 2>&1
amixer -c 0 cset name='ADC2_MIXER Switch'                    1          >/dev/null 2>&1
amixer -c 0 cset name='TX_DEC0 Volume'                       82         >/dev/null 2>&1
amixer -c 0 cset name='TX_AIF1_CAP Mixer DEC0'               1          >/dev/null 2>&1
amixer -c 0 cset name='MultiMedia3 Mixer TX_CODEC_DMA_TX_3'  1          >/dev/null 2>&1
logger "mic-uno-q: mixer OK"
EOF
  chmod +x /usr/local/bin/mic-uno-q-init.sh

  cat > /etc/systemd/system/mic-uno-q.service << 'EOF'
[Unit]
Description=Arduino UNO Q analog microphone ALSA mixer setup
After=sound.target alsa-restore.service
Wants=sound.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/mic-uno-q-init.sh
RemainAfterExit=yes
EOF

  # Clean up any timer from previous iterations of this script
  if systemctl list-unit-files mic-uno-q.timer >/dev/null 2>&1 && \
     [ -f /etc/systemd/system/mic-uno-q.timer ]; then
    systemctl disable --now mic-uno-q.timer 2>/dev/null
    rm -f /etc/systemd/system/mic-uno-q.timer
  fi

  systemctl daemon-reload
  systemctl enable --now mic-uno-q.service
  ok "mic-uno-q.service enabled."

  touch "${STAMP_ALSA}"
  ok "Step 1 complete."
}

# ---------------------------------------------------------------------------
# Step 2 — /dev/snd/by-id symlink + udev rule (REQUIRED by arduino-app-cli)
# ---------------------------------------------------------------------------
# arduino-app-cli's deploy path validates the presence of
# a USB-like ALSA device under /dev/snd/by-id/usb-* before authorizing apps
# that use the keyword_spotting brick. The Arduino UNO Q codec is on a SoC bus,
# not USB, so we create a fake `usb-Arduino_Analog_Microphone-00` symlink that
# satisfies the check. The Python runtime side bypasses this entirely by
# passing an explicit ALSA device name (plughw:CARD=ArduinoImolaHPH,DEV=2).
# ---------------------------------------------------------------------------
setup_udev() {
  if [ -f "${STAMP_UDEV}" ]; then
    skipped "udev rule already installed."; return
  fi
  info "Step 2: /dev/snd/by-id symlink + udev rule (required by deploy validator)..."

  # Create immediately for this session
  mkdir -p /dev/snd/by-id
  ln -sf /dev/snd/pcmC0D2c /dev/snd/by-id/usb-Arduino_Analog_Microphone-00
  ok "Created /dev/snd/by-id/usb-Arduino_Analog_Microphone-00"

  # Persistent udev rule — recreates symlink on each boot
  cat > "${UDEV_RULE}" << 'EOF'
# Arduino UNO Q — fake USB mic entry for arduino-app-cli device check
# arduino-app-cli requires /dev/snd/by-id/<name> at deployment time to detect
# the microphone. The board has no USB audio; this rule creates the expected
# symlink. The Python runtime uses plughw:CARD=ArduinoImolaHPH,DEV=2 directly.
ACTION=="add", KERNEL=="pcmC0D2c", SUBSYSTEM=="sound", RUN+="/bin/mkdir -p /dev/snd/by-id", RUN+="/bin/ln -sf /dev/snd/pcmC0D2c /dev/snd/by-id/usb-Arduino_Analog_Microphone-00"
EOF
  udevadm control --reload-rules
  udevadm trigger --action=add --subsystem-match=sound
  ok "udev rule installed: ${UDEV_RULE}"

  touch "${STAMP_UDEV}"
  ok "Step 2 complete."
}

# ---------------------------------------------------------------------------
# Step 3 — Deploy UNO Q EchoGlow example to ArduinoApps
# ---------------------------------------------------------------------------
# App Lab 0.10+ reorganized the examples catalog: examples no longer live at
# the root of examples/, they live under board-scoped categories, and App
# Lab's indexer only scans those category folders. EchoGlow is UNO Q-specific
# (analog mic + Qwiic), so it belongs under inspirational/platform_unoq/, not
# the examples/ root — deploying to the root makes the app invisible in App
# Lab even though the files are on disk.
# ---------------------------------------------------------------------------
deploy_example() {
  info "Step 3: Deploying uno-q-echoglow to examples..."

  local script_dir
  script_dir="$(dirname "$(realpath "$0")")"
  local src="${script_dir}/uno-q-echoglow"
  local examples_dir
  examples_dir="$(_detect_examples_dir)"
  local dest="${examples_dir}/inspirational/platform_unoq/uno-q-echoglow"
  local old_dest="${examples_dir}/uno-q-echoglow"

  if [ ! -d "${src}" ]; then
    warn "Example folder not found: ${src}"
    warn "Make sure uno-q-echoglow/ is next to this script."
    return
  fi

  if ! id arduino >/dev/null 2>&1; then
    fail "User 'arduino' not found — is this an Arduino UNO Q board?"
  fi

  # Clean up a stale deploy from a previous version of this script that
  # copied to the examples/ root (invisible to App Lab's category indexer).
  if [ -d "${old_dest}" ]; then
    rm -rf "${old_dest}"
    ok "Removed stale deployment at ${old_dest}"
  fi

  mkdir -p "${dest}"
  cp -r "${src}/." "${dest}"
  chown -R arduino:arduino "${dest}"
  ok "Example deployed to ${dest}"
  ok "Step 3 complete."
}

# ---------------------------------------------------------------------------
# Step 4 — Patch arduino:zephyr gpio_lowlevel_stm32.h regression
# ---------------------------------------------------------------------------
# arduino:zephyr 0.55.0 ships variants/common/gpio_lowlevel_stm32.h with
# portOutputRegister(x)/portInputRegister(x) taking a pin number — violating
# the AVR/Arduino convention `portOutputRegister(digitalPinToPort(pin))` used
# by Adafruit_BusIO 1.16.1 and many other libraries, breaking compilation of
# sketches that include those libs. Fix: receive a port (GPIO_TypeDef*) and
# cast it. Idempotent; only modifies the matching macro line.
# ---------------------------------------------------------------------------
patch_zephyr_gpio_header() {
  if [ -f "${STAMP_ZEPHYR}" ]; then
    skipped "zephyr gpio header already patched."; return
  fi
  info "Step 4: Patching arduino:zephyr gpio_lowlevel_stm32.h (Adafruit_BusIO fix)..."

  local arduino_home="/home/arduino/.arduino15/packages/arduino/hardware/zephyr"
  if [ ! -d "$arduino_home" ]; then
    skipped "arduino:zephyr core not installed."
    return
  fi

  local patched_any=0 already_patched_any=0
  for verdir in "$arduino_home"/*/; do
    local hdr="${verdir}variants/common/gpio_lowlevel_stm32.h"
    [ -f "$hdr" ] || continue

    if grep -q "^#define portOutputRegister(port)" "$hdr"; then
      info "Already patched: ${hdr}"
      already_patched_any=1
      continue
    fi

    if grep -q "^#define portOutputRegister(x)  (digitalPinToPort(x)->ODR)" "$hdr"; then
      cp -a "$hdr" "${hdr}.bak.$(date +%Y%m%d_%H%M%S)"
      sed -i \
        -e "s|^#define portOutputRegister(x)  (digitalPinToPort(x)->ODR)|#define portOutputRegister(port) (((GPIO_TypeDef *)(port))->ODR)|" \
        -e "s|^#define portInputRegister(x)   (digitalPinToPort(x)->IDR)|#define portInputRegister(port)  (((GPIO_TypeDef *)(port))->IDR)|" \
        "$hdr"
      ok "Patched ${hdr}"
      patched_any=1
    fi
  done

  if [ "$patched_any" -eq 0 ] && [ "$already_patched_any" -eq 0 ]; then
    warn "No matching gpio_lowlevel_stm32.h found — unknown zephyr version?"
  fi

  warn "Note: this patch is overwritten on every arduino:zephyr core update; re-run this script after updates."
  touch "${STAMP_ZEPHYR}"
  ok "Step 4 complete."
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------
verify() {
  info "Verification..."
  local ok_count=0 warn_count=0

  check() {
    local label="$1"; shift
    if eval "$@" >/dev/null 2>&1; then
      ok "${label}"; ok_count=$((ok_count + 1))
    else
      warn "${label} — FAILED"; warn_count=$((warn_count + 1))
    fi
  }

  check "ALSA device present"             "arecord -l | grep -q ArduinoImolaHPH"
  check "/etc/asound.conf absent"         "! test -f ${ASOUND_CONF}"
  check "mic-uno-q.service active"        "systemctl is-active mic-uno-q.service"
  check "USB symlink present"             "test -L /dev/snd/by-id/usb-Arduino_Analog_Microphone-00"
  check "udev rule present"               "test -f ${UDEV_RULE}"

  if docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1; then
    ok "Docker image present"; ok_count=$((ok_count + 1))
  else
    warn "Docker image not present locally (will pull on first app run)"
    warn_count=$((warn_count + 1))
  fi

  # Zephyr gpio header — verify all installed versions are patched
  local hdr_found=0
  for hdr in /home/arduino/.arduino15/packages/arduino/hardware/zephyr/*/variants/common/gpio_lowlevel_stm32.h; do
    [ -f "$hdr" ] || continue
    hdr_found=1
    check "zephyr gpio header patched ($(basename $(dirname $(dirname $(dirname "$hdr")))))" \
      "grep -q '^#define portOutputRegister(port)' '$hdr'"
  done
  [ "$hdr_found" -eq 0 ] && info "(no arduino:zephyr core installed — skipping gpio header check)"

  local examples_dir; examples_dir="$(_detect_examples_dir)"
  check "uno-q-echoglow in examples" \
    "test -f ${examples_dir}/inspirational/platform_unoq/uno-q-echoglow/app.yaml"

  echo ""
  if [ "${warn_count}" -eq 0 ]; then
    ok "All checks passed (${ok_count}/${ok_count})."
  else
    warn "${ok_count} OK, ${warn_count} warnings."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  echo ""
  info "============================================================"
  info " Arduino UNO Q Microphone Setup for Arduino Lab"
  info " (firmware bundle ${APP_CLI_VERSION})"
  info "============================================================"
  echo ""
  preflight_checks
  setup_alsa
  setup_udev
  deploy_example
  patch_zephyr_gpio_header
  verify
  echo ""
  ok "Setup complete."
  info "Reboot recommended to verify systemd persistence."
}

case "${1:-}" in
  --verify-only)
    preflight_checks
    verify
    ;;
  --deploy-example)
    [ "$(id -u)" -eq 0 ] || fail "Run as root: sudo $0 $1"
    deploy_example
    ;;
  --help|-h)
    echo "Usage: sudo $0 [--verify-only | --deploy-example]"
    echo ""
    echo "  --verify-only     Run preflight + verification only (no changes)"
    echo "  --deploy-example  Re-deploy uno-q-echoglow into examples/"
    echo ""
    echo "  Env: APP_CLI_VERSION  Override auto-detected firmware version"
    ;;
  *)
    main
    ;;
esac
