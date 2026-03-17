#!/usr/bin/env bash
# =============================================================================
# setup-arduino-q-mic-applab.sh
#
# Reproducible setup for the analog microphone on Arduino UNO Q
# with Arduino Lab / Arduino App CLI (keyword-spotting / Hey Arduino!).
#
# Usage:
#   chmod +x setup-arduino-q-mic-applab.sh
#   sudo ./setup-arduino-q-mic-applab.sh
#
# Safe to run multiple times (idempotent).
#
# What this script does:
#   1. ALSA mixer + /etc/asound.conf + mic-uno-q.service (boot-time mixer init)
#   2. /dev/snd/by-id symlink + udev rule (arduino-app-cli device detection)
#   3. Docker image patch — analog mic fallback in Python Microphone class
#      NOTE: The Qualcomm LPASS mixer resets on every PCM session close.
#            The patch re-runs amixer before each PCM open, and uses the
#            full ALSA device name (plughw:CARD=ArduinoImolaHPH,DEV=2).
#   4. app-compose-overrides.yaml — deploy to all keyword-spotting apps
#      (mounts /dev/snd and /etc/asound.conf into the main container)
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration — override via environment variables if needed
# ---------------------------------------------------------------------------

# Auto-detect arduino-app-cli version from assets directory
# Checks both /var/lib and ~/.local/share locations
_detect_version() {
  local v
  for base in /var/lib/arduino-app-cli ~/.local/share/arduino-app-cli; do
    if [ -d "${base}/assets" ]; then
      v=$(ls "${base}/assets" 2>/dev/null | sort -V | tail -1)
      [ -n "$v" ] && echo "$v" && return
    fi
  done
  echo "0.7.3"  # fallback default
}

APP_CLI_VERSION="${APP_CLI_VERSION:-$(_detect_version)}"
DOCKER_IMAGE="ghcr.io/arduino/app-bricks/python-apps-base:${APP_CLI_VERSION}"
UDEV_RULE="/etc/udev/rules.d/99-arduino-uno-q-mic.rules"
ASOUND_CONF="/etc/asound.conf"
STAMP_DIR="/var/lib/arduino-uno-q-setup"
STAMP_ALSA="${STAMP_DIR}/alsa_done"
STAMP_UDEV="${STAMP_DIR}/udev_done"
STAMP_DOCKER="${STAMP_DIR}/docker_patched_v3_${APP_CLI_VERSION}"

# Examples dir — check both /var/lib and ~/.local/share
_detect_examples_dir() {
  for base in /var/lib/arduino-app-cli ~/.local/share/arduino-app-cli; do
    [ -d "${base}/examples" ] && echo "${base}/examples" && return
  done
  echo "/var/lib/arduino-app-cli/examples"  # fallback
}
EXAMPLES_DIR="$(_detect_examples_dir)"

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
  if ! aplay -l 2>/dev/null | grep -q "ArduinoImolaHPH"; then
    warn "ArduinoImolaHPH codec not detected — wait for ALSA driver to load, then re-run."
    warn "Check with: arecord -l | grep ArduinoImolaHPH"
  fi
  mkdir -p "${STAMP_DIR}"
  ok "Preflight OK."
}

# ---------------------------------------------------------------------------
# Step 1 — ALSA mixer + asound.conf + systemd service
# ---------------------------------------------------------------------------
setup_alsa() {
  if [ -f "${STAMP_ALSA}" ]; then
    skipped "ALSA already configured."; return
  fi
  info "Step 1: ALSA mixer, /etc/asound.conf, mic-uno-q.service..."

  # NOTE: The Qualcomm LPASS mixer resets after every PCM session close.
  # This initial setup matters for the boot-time service, but the Docker
  # patch (step 3) re-runs amixer before each PCM open inside the container.
  local cmds=(
    "cset name='TX DEC0 MUX' SWR_MIC"
    "cset name='TX SMIC MUX0' SWR_MIC1"
    "cset name='ADC2 MUX' INP2"
    "cset name='ADC2 Switch' 1"
    "cset name='ADC2 Volume' 8"
    "cset name='ADC2_MIXER Switch' 1"
    "cset name='TX_DEC0 Volume' 82"
    "cset name='TX_AIF1_CAP Mixer DEC0' 1"
    "cset name='MultiMedia3 Mixer TX_CODEC_DMA_TX_3' 1"
  )
  for cmd in "${cmds[@]}"; do
    amixer -c 0 ${cmd} >/dev/null 2>&1 && true || warn "amixer skip: $cmd"
  done
  ok "Mixer configured."

  # /etc/asound.conf — routes default capture to hw:0,2
  [ -f "${ASOUND_CONF}" ] && cp "${ASOUND_CONF}" "${ASOUND_CONF}.bak"
  cat > "${ASOUND_CONF}" << 'EOF'
# Arduino UNO Q analog microphone — setup-arduino-q-mic-applab.sh
pcm.mm3_cap {
    type plug
    slave.pcm "hw:0,2"
}

pcm.!default {
    type asym
    capture.pcm  "mm3_cap"
    playback.pcm "plughw:0,0"
}

ctl.!default {
    type hw
    card 0
}
EOF
  ok "Written ${ASOUND_CONF}"

  # Boot-time init script — runs amixer after alsa driver loads
  cat > /usr/local/bin/mic-uno-q-init.sh << 'EOF'
#!/bin/bash
# Wait for ALSA driver to be ready
for i in $(seq 1 10); do
    arecord -l 2>/dev/null | grep -q "ArduinoImolaHPH" && break
    sleep 2
done
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

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now mic-uno-q.service
  ok "mic-uno-q.service enabled."

  touch "${STAMP_ALSA}"
  ok "Step 1 complete."
}

# ---------------------------------------------------------------------------
# Step 2 — /dev/snd/by-id symlink + udev rule
# ---------------------------------------------------------------------------
setup_udev() {
  if [ -f "${STAMP_UDEV}" ]; then
    skipped "udev rule already installed."; return
  fi
  info "Step 2: /dev/snd/by-id symlink + udev rule..."

  # Create immediately for this session
  mkdir -p /dev/snd/by-id
  ln -sf /dev/snd/pcmC0D2c /dev/snd/by-id/usb-Arduino_Analog_Microphone-00
  ok "Created /dev/snd/by-id/usb-Arduino_Analog_Microphone-00"

  # Persistent udev rule — recreates symlink on each boot
  cat > "${UDEV_RULE}" << 'EOF'
# Arduino UNO Q — fake USB mic entry for arduino-app-cli device check
# arduino-app-cli requires /dev/snd/by-id/<name> to detect the microphone.
# The board has no USB audio; this rule creates the expected symlink.
ACTION=="add", KERNEL=="pcmC0D2c", SUBSYSTEM=="sound", \
    RUN+="/bin/mkdir -p /dev/snd/by-id", \
    RUN+="/bin/ln -sf /dev/snd/pcmC0D2c /dev/snd/by-id/usb-Arduino_Analog_Microphone-00"
EOF
  udevadm control --reload-rules
  udevadm trigger --subsystem-match=sound
  ok "udev rule installed: ${UDEV_RULE}"

  touch "${STAMP_UDEV}"
  ok "Step 2 complete."
}

# ---------------------------------------------------------------------------
# Step 3 — Patch Docker image with analog mic fallback (v3)
#
# Why this patch is needed:
#   - The Python Microphone class only looks for USB mics; analog mics are
#     not USB, so it always fails without this patch.
#   - The Qualcomm LPASS (Q6ASM) resets ALSA mixer controls to "off" every
#     time a PCM capture session closes. So we must re-run amixer before
#     opening the PCM device — not just once at boot.
#   - Inside Docker containers, short ALSA names (hw:0,2) fail. The full
#     name plughw:CARD=ArduinoImolaHPH,DEV=2 must be used.
# ---------------------------------------------------------------------------
patch_docker_image() {
  if [ -f "${STAMP_DOCKER}" ]; then
    skipped "Docker image already patched (v3) for v${APP_CLI_VERSION}."; return
  fi
  info "Step 3: Patching Docker image ${DOCKER_IMAGE}..."

  if ! docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1; then
    info "Pulling ${DOCKER_IMAGE}..."
    docker pull "${DOCKER_IMAGE}" || fail "Failed to pull ${DOCKER_IMAGE}"
  fi

  # Write patch script to a temp file and mount it (stdin heredoc fails with sudo -S)
  local patch_script
  patch_script=$(mktemp /tmp/arduino_mic_patch_XXXXXX.py)
  cat > "${patch_script}" << 'PYEOF'
import glob, os, sys

candidates = glob.glob('/usr/local/lib/python3*/site-packages/arduino/app_peripherals/microphone/__init__.py')
if not candidates:
    print('ERROR: microphone __init__.py not found', file=sys.stderr)
    sys.exit(1)

path = candidates[0]
lines = open(path).readlines()

SENTINEL = 'ARDUINO_UNO_Q_ANALOG_FALLBACK_V3'
if any(SENTINEL in l for l in lines):
    print('Patch v3 already applied.')
    sys.exit(0)

# Find the 'if not usb_devices:' block and its end (raise MicrophoneException)
start = None
for i, l in enumerate(lines):
    if 'if not usb_devices:' in l:
        start = i; break

if start is None:
    print('ERROR: target line not found', file=sys.stderr)
    sys.exit(1)

end = start + 1
for i in range(start + 1, len(lines)):
    if 'raise MicrophoneException' in lines[i] and 'No USB' in lines[i]:
        end = i + 1; break

# Build replacement block (indented to match existing code)
pad = ' ' * (len(lines[start]) - len(lines[start].lstrip()))

patch = [
    pad + 'if not usb_devices:\n',
    pad + '    # ' + SENTINEL + '\n',
    pad + '    import subprocess as _sp, alsaaudio as _a\n',
    pad + '    def _setup_mixer():\n',
    pad + '        _cmds = [\n',
    pad + '            ["amixer","-c","0","cset","name=TX DEC0 MUX","SWR_MIC"],\n',
    pad + '            ["amixer","-c","0","cset","name=TX SMIC MUX0","SWR_MIC1"],\n',
    pad + '            ["amixer","-c","0","cset","name=ADC2 MUX","INP2"],\n',
    pad + '            ["amixer","-c","0","cset","name=ADC2 Switch","1"],\n',
    pad + '            ["amixer","-c","0","cset","name=ADC2 Volume","8"],\n',
    pad + '            ["amixer","-c","0","cset","name=ADC2_MIXER Switch","1"],\n',
    pad + '            ["amixer","-c","0","cset","name=TX_DEC0 Volume","82"],\n',
    pad + '            ["amixer","-c","0","cset","name=TX_AIF1_CAP Mixer DEC0","1"],\n',
    pad + '            ["amixer","-c","0","cset","name=MultiMedia3 Mixer TX_CODEC_DMA_TX_3","1"],\n',
    pad + '        ]\n',
    pad + '        for _c in _cmds:\n',
    pad + '            _sp.run(_c, capture_output=True)\n',
    pad + '    _setup_mixer()\n',
    pad + '    _pcms = _a.pcms(_a.PCM_CAPTURE)\n',
    pad + '    _candidates = [d for d in _pcms if "DEV=2" in d and "plughw" in d]\n',
    pad + '    if not _candidates:\n',
    pad + '        _candidates = [d for d in _pcms if "DEV=2" in d]\n',
    pad + '    for _dev in _candidates:\n',
    pad + '        try:\n',
    pad + '            _t = _a.PCM(_a.PCM_CAPTURE, device=_dev); _t.close()\n',
    pad + '            logger.warning("No USB mic, analog fallback: %s", _dev)\n',
    pad + '            return _dev\n',
    pad + '        except Exception as e:\n',
    pad + '            logger.warning("Fallback %s failed: %s", _dev, e)\n',
    pad + '            continue\n',
    pad + '    logger.error("No USB microphones found")\n',
    pad + '    raise MicrophoneException("No USB microphone found.")\n',
]

lines[start:end] = patch
tmp = path + '.tmp'
open(tmp, 'w').writelines(lines)
os.rename(tmp, path)
print('Patch v3 applied to', path)
PYEOF

  docker run --user root --name arduino-mic-patch \
    -v "${patch_script}:/tmp/patch.py:ro" \
    --entrypoint python3 \
    "${DOCKER_IMAGE}" /tmp/patch.py
  rm -f "${patch_script}"

  docker commit arduino-mic-patch "${DOCKER_IMAGE}"
  docker rm arduino-mic-patch
  ok "Docker image patched (v3) and committed as ${DOCKER_IMAGE}."

  touch "${STAMP_DOCKER}"
  ok "Step 3 complete."
}

# ---------------------------------------------------------------------------
# Step 4 — Deploy app-compose-overrides.yaml to all keyword-spotting apps
# ---------------------------------------------------------------------------
deploy_overrides() {
  info "Step 4: Deploying app-compose-overrides.yaml to keyword-spotting apps..."

  local override_content
  override_content=$(cat << 'EOF'
# app-compose-overrides.yaml — Arduino UNO Q analog microphone support
# Generated by setup-arduino-q-mic-applab.sh
services:
  main:
    devices:
      - /dev/snd
    volumes:
      - type: bind
        source: /etc/asound.conf
        target: /etc/asound.conf
        read_only: true
EOF
)

  local deployed=0

  # Deploy to all example apps that use keyword_spotting brick
  if [ -d "${EXAMPLES_DIR}" ]; then
    for app_dir in "${EXAMPLES_DIR}"/*/; do
      [ -d "$app_dir" ] || continue
      # Check if this app uses the keyword_spotting brick
      if grep -r "keyword_spotting\|keyword-spotting" "${app_dir}" >/dev/null 2>&1; then
        local override_file="${app_dir}app-compose-overrides.yaml"
        echo "$override_content" > "${override_file}"
        ok "Deployed: ${override_file}"
        deployed=$((deployed + 1))
      fi
    done
  else
    warn "${EXAMPLES_DIR} not found — arduino-app-cli not installed?"
  fi

  # Also deploy to all user apps that use keyword_spotting
  local user_apps_dir="/home/arduino/ArduinoApps"
  if [ -d "${user_apps_dir}" ]; then
    for app_dir in "${user_apps_dir}"/*/; do
      [ -d "$app_dir" ] || continue
      if grep -r "keyword_spotting\|keyword-spotting" "${app_dir}" >/dev/null 2>&1; then
        local override_file="${app_dir}app-compose-overrides.yaml"
        echo "$override_content" > "${override_file}"
        ok "Deployed (user app): ${override_file}"
        deployed=$((deployed + 1))
      fi
    done
  fi

  if [ "${deployed}" -eq 0 ]; then
    warn "No keyword-spotting apps found. If you create one, run:"
    warn "  sudo $0 --deploy-overrides-only"
  else
    ok "Deployed to ${deployed} app(s)."
  fi

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

  check "ALSA device present"            "arecord -l | grep -q ArduinoImolaHPH"
  check "asound.conf exists"             "test -f ${ASOUND_CONF}"
  check "mic-uno-q.service enabled"      "systemctl is-enabled mic-uno-q.service"
  check "/dev/snd/by-id symlink"         "test -L /dev/snd/by-id/usb-Arduino_Analog_Microphone-00"
  check "udev rule file"                 "test -f ${UDEV_RULE}"

  if docker image inspect "${DOCKER_IMAGE}" >/dev/null 2>&1; then
    if [ -f "${STAMP_DOCKER}" ]; then
      ok "Docker image patched (v3)"; ok_count=$((ok_count + 1))
    else
      warn "Docker image not patched — run setup again"; warn_count=$((warn_count + 1))
    fi
  else
    warn "Docker image not present locally"; warn_count=$((warn_count + 1))
  fi

  # Re-detect examples dir (may have been created after script started)
  EXAMPLES_DIR="$(_detect_examples_dir)"
  # Check override deployed to keyword-spotting example (only if examples dir exists)
  local ks_example="${EXAMPLES_DIR}/keyword-spotting/app-compose-overrides.yaml"
  if [ -d "${EXAMPLES_DIR}" ]; then
    if [ -f "${ks_example}" ]; then
      check "override in keyword-spotting example" "grep -q '/dev/snd' ${ks_example}"
    else
      warn "No override at ${ks_example} — run: sudo $0 --deploy-overrides-only"
      warn_count=$((warn_count + 1))
    fi
  else
    ok "examples dir not yet initialized (run --deploy-overrides-only after first launch)"
    ok_count=$((ok_count + 1))
  fi

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
  info " Arduino UNO Q Microphone Setup for Arduino Lab v${APP_CLI_VERSION}"
  info "============================================================"
  echo ""
  preflight_checks
  setup_alsa
  setup_udev
  patch_docker_image
  deploy_overrides
  verify
  echo ""
  ok "Setup complete."
  info "Reboot recommended to verify udev and systemd persistence."
  info ""
  info "For new keyword-spotting apps created after setup, run:"
  info "  sudo $0 --deploy-overrides-only"
}

case "${1:-}" in
  --verify-only)
    preflight_checks
    verify
    ;;
  --deploy-overrides-only)
    [ "$(id -u)" -eq 0 ] || fail "Run as root: sudo $0 $1"
    deploy_overrides
    ;;
  --help|-h)
    echo "Usage: sudo $0 [--verify-only | --deploy-overrides-only]"
    echo "  APP_CLI_VERSION env var overrides version (default: 0.7.3)"
    ;;
  *)
    main
    ;;
esac
