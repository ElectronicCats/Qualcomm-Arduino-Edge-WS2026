#!/usr/bin/env bash
# =============================================================================
# prepare-board.sh - get an Arduino UNO Q ready for the EchoGlow workshop
#
# Run on the LAPTOP (macOS or Linux), with the board connected over USB.
#
# Before running: the board must already be updated by Arduino App Lab
# (connect it in App Lab, finish its setup, accept the update), and App Lab
# must be closed so this script can use the USB connection.
#
# What it does, per board connected over USB:
#   1. copies Software/ to /home/arduino/Qualcomm-Arduino-Edge-WS2026/
#   2. runs: sudo Software/setup-arduino-q-mic-applab.sh --system
#      (analog mic service, /dev/snd/by-id entry + udev rule)
#   3. installs EchoGlow in App Lab "My Apps"
#   4. stops adb so App Lab can connect again
#
# BOARD_PASSWORD is the password you set in App Lab; it is only used for sudo.
#
# Usage:
#   BOARD_PASSWORD=<password> Software/prepare-board.sh
#
# Requires: adb (Android platform-tools).
# =============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REMOTE_ROOT="/home/arduino/Qualcomm-Arduino-Edge-WS2026"
REMOTE_SW="${REMOTE_ROOT}/Software"
LOG_DIR="$(pwd)/logs"
# adb shells on the UNO Q set TMPDIR=/data/local/tmp, which does not exist
# on the board and breaks arduino-app-cli. Every board command uses /tmp.
RPRE="export TMPDIR=/tmp;"

command -v adb >/dev/null 2>&1 || { echo "adb not found. Install Android platform-tools." >&2; exit 1; }
[ -n "${BOARD_PASSWORD:-}" ] || { echo "Set BOARD_PASSWORD, e.g. BOARD_PASSWORD=<password> $0" >&2; exit 1; }

SERIALS="$(adb devices | awk 'NR>1 && $2=="device" {print $1}')"
if [ -z "${SERIALS}" ]; then
  echo "No board found over USB." >&2
  echo "Check: USB-C data cable plugged in, App Lab closed, then run 'adb devices'." >&2
  adb kill-server >/dev/null 2>&1
  exit 1
fi

mkdir -p "${LOG_DIR}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT
TARBALL="${TMP_DIR}/software.tar"
COPYFILE_DISABLE=1 tar --no-xattrs -C "${SCRIPT_DIR}/.." -cf "${TARBALL}" \
  --exclude '.DS_Store' Software || { echo "Could not package Software/" >&2; exit 1; }

rsh() { local s="$1"; shift; adb -s "$s" shell "${RPRE} $*"; }

step_copy() {
  adb -s "$1" push "${TARBALL}" /tmp/echoglow-software.tar >/dev/null || return 1
  rsh "$1" "mkdir -p ${REMOTE_ROOT} && rm -rf ${REMOTE_SW} \
    && tar -C ${REMOTE_ROOT} -xf /tmp/echoglow-software.tar && rm -f /tmp/echoglow-software.tar \
    && chmod +x ${REMOTE_SW}/*.sh"
}

step_mic_setup() {
  local out
  out="$(printf '%s\n' "${BOARD_PASSWORD}" | adb -s "$1" shell \
    "${RPRE} sudo -S -p '' ${REMOTE_SW}/setup-arduino-q-mic-applab.sh --system; echo __RC=\$?")"
  echo "${out}"
  echo "${out}" | grep -q '^__RC=0'
}

step_my_apps() {
  rsh "$1" "mkdir -p /home/arduino/ArduinoApps && rm -rf /home/arduino/ArduinoApps/uno-q-echoglow \
    && cp -r ${REMOTE_SW}/uno-q-echoglow /home/arduino/ArduinoApps/uno-q-echoglow \
    && arduino-app-cli app list 2>/dev/null" | grep -q 'user:uno-q-echoglow'
}

FAILED=0
for s in ${SERIALS}; do
  log="${LOG_DIR}/prepare-${s}.log"
  start=$(date +%s)
  echo "== Board ${s}"
  result="OK"
  {
    echo "=== ${s} $(date '+%Y-%m-%d %H:%M:%S')"
    rsh "$s" "dpkg-query -W -f='\${Package} \${Version}\n' arduino-app-lab 2>/dev/null"
  } > "${log}" 2>&1
  if   ! step_copy      "$s" >> "${log}" 2>&1; then result="FAIL: could not copy files"
  elif ! step_mic_setup "$s" >> "${log}" 2>&1; then result="FAIL: mic setup (wrong password? see log)"
  elif ! step_my_apps   "$s" >> "${log}" 2>&1; then result="FAIL: could not add EchoGlow to My Apps"
  fi
  secs=$(( $(date +%s) - start ))
  echo "${result}  (${secs}s, $(grep -m1 arduino-app-lab "${log}" || echo 'App Lab version unknown'))" | tee -a "${log}"
  [ "${result}" = "OK" ] || { FAILED=$((FAILED + 1)); echo "   log: ${log}"; }
done

adb kill-server >/dev/null 2>&1   # give USB back to App Lab
echo ""
[ "${FAILED}" -eq 0 ] && echo "Done. Open App Lab: EchoGlow is in My Apps." || echo "${FAILED} board(s) failed."
exit "${FAILED}"
