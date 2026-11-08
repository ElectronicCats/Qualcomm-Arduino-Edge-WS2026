#!/usr/bin/env bash
# =============================================================================
# golden-image.sh - clone one finished UNO Q onto other boards
#
# Runs on the LAPTOP (macOS). Needs: qdl (brew install qdl), adb, and the
# official image extracted in IMAGE_DIR (the folder that has flash/ and the
# disk-sdcard.img.* files). The golden board MUST have been flashed from
# this same official image, then updated in App Lab and prepared with
# prepare-board.sh.
#
# Steps:
#   1. prep     golden board connected normally (adb). Cleans apt cache,
#               empties /etc/machine-id (so every clone gets its own ID on
#               first boot) and powers the board off.
#   2. capture  golden board in EDL mode (JCTL jumper GND-USB_BOOT, then USB).
#               Reads partitions efi, rootfs and userdata with qdl and builds
#               GOLDEN_DIR = copy of IMAGE_DIR with those three files replaced.
#   3. flash    target board in EDL mode. Flashes GOLDEN_DIR with the official
#               arduino-flasher-cli.
#
# Usage:
#   BOARD_PASSWORD=<password> Software/golden-image.sh prep
#   Software/golden-image.sh capture
#   Software/golden-image.sh flash
#   BOARD_PASSWORD=<password> Software/golden-image.sh finish echoglow-01
#                (after the clone boots: unique name + new machine-id)
#
# Env (defaults in brackets):
#   FLASH_DIR  [~/Downloads/unoq-flash]                     flasher + image
#   IMAGE_DIR  [$FLASH_DIR/image/arduino-unoq-debian-image-20260528-558]
#   GOLDEN_DIR [$FLASH_DIR/golden/arduino-unoq-debian-image-20260528-558]
# =============================================================================

set -eu

FLASH_DIR="${FLASH_DIR:-$HOME/Downloads/unoq-flash}"
IMAGE_DIR="${IMAGE_DIR:-${FLASH_DIR}/image/arduino-unoq-debian-image-20260528-558}"
GOLDEN_DIR="${GOLDEN_DIR:-${FLASH_DIR}/golden/arduino-unoq-debian-image-20260528-558}"
PROG="${IMAGE_DIR}/flash/prog_firehose_ddr.elf"

die() { echo "ERROR: $*" >&2; exit 1; }

case "${1:-}" in
  prep)
    [ -n "${BOARD_PASSWORD:-}" ] || die "set BOARD_PASSWORD"
    command -v adb >/dev/null || die "adb not found"
    n="$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')"
    [ "$n" = "1" ] || die "connect exactly one board (the golden one); found $n"
    printf '%s\n' "${BOARD_PASSWORD}" | adb shell \
      "sudo -S -p '' sh -c 'apt-get clean; truncate -s 0 /etc/machine-id; sync; echo PREP_OK; poweroff'" \
      | grep -q PREP_OK || die "prep failed (password?)"
    adb kill-server >/dev/null 2>&1 || true
    echo "Golden board prepared and powering off."
    echo "Next: unplug it, put the jumper on JCTL GND-USB_BOOT, plug it in, run: $0 capture"
    ;;

  capture)
    command -v qdl >/dev/null || die "qdl not found (brew install qdl)"
    [ -f "${PROG}" ] || die "programmer not found: ${PROG}"
    out="${FLASH_DIR}/golden-dump"
    mkdir -p "${out}"
    echo "Reading efi, rootfs, userdata from the board in EDL mode (several minutes)..."
    start=$(date +%s)
    qdl --storage emmc "${PROG}" \
      read efi "${out}/disk-sdcard.img.esp" \
      read rootfs "${out}/disk-sdcard.img.root" \
      read userdata "${out}/disk-sdcard.img.home"
    echo "Read done in $(( $(date +%s) - start ))s:"
    ls -la "${out}"
    echo "Building ${GOLDEN_DIR} ..."
    rm -rf "${GOLDEN_DIR}"
    mkdir -p "$(dirname "${GOLDEN_DIR}")"
    cp -c -R "${IMAGE_DIR}" "${GOLDEN_DIR}" 2>/dev/null || cp -R "${IMAGE_DIR}" "${GOLDEN_DIR}"
    for f in disk-sdcard.img.esp disk-sdcard.img.root disk-sdcard.img.home; do
      mv -f "${out}/${f}" "${GOLDEN_DIR}/${f}"
    done
    echo "Golden image ready: ${GOLDEN_DIR}"
    echo "Unplug the golden board, remove the jumper."
    ;;

  flash)
    [ -d "${GOLDEN_DIR}/flash" ] || die "no golden image yet, run capture first"
    cd "${FLASH_DIR}"
    start=$(date +%s)
    ./arduino-flasher-cli flash unoq "$(dirname "${GOLDEN_DIR}")" -y
    echo "Flash done in $(( $(date +%s) - start ))s. Unplug, remove the jumper, plug in."
    ;;

  finish)
    # After a clone has booted (jumper removed): give it its own name and a
    # new machine-id (the clone starts with the golden board's).
    name="${2:-}"
    [ -n "${name}" ] || die "usage: BOARD_PASSWORD=<password> $0 finish <board-name>"
    [ -n "${BOARD_PASSWORD:-}" ] || die "set BOARD_PASSWORD"
    n="$(adb devices | awk 'NR>1 && $2=="device"' | wc -l | tr -d ' ')"
    [ "$n" = "1" ] || die "connect exactly one booted board; found $n"
    adb shell "export TMPDIR=/tmp; arduino-app-cli system set-name '${name}'" || die "set-name failed"
    printf '%s\n' "${BOARD_PASSWORD}" | adb shell \
      "sudo -S -p '' sh -c 'systemd-id128 new > /etc/machine-id && echo machine-id: \$(cat /etc/machine-id); reboot'" \
      || die "machine-id update failed"
    adb kill-server >/dev/null 2>&1 || true
    echo "Board named ${name}, new machine-id, rebooting. Unplug when you like."
    ;;

  *)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
    exit 1
    ;;
esac
