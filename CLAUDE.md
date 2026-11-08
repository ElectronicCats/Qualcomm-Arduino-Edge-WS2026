# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Workshop material for "UNO Q EchoGlow": a voice-controlled NeoPixel light on the Arduino UNO Q (Qualcomm QRB2210 Linux side + STM32 Zephyr MCU side). Keywords "Warmer-light", "Cooler-light", "Dimmer", "Brighter" come from an Edge Impulse model run by the App Lab `keyword_spotting` brick, using the board's analog microphone (not a USB mic).

- `Software/uno-q-echoglow/` - the Arduino App Lab app (deployed to the board, not built locally).
- `Software/setup-arduino-q-mic-applab.sh` - one-time, root, on-board setup script that makes the analog mic usable by App Lab.
- `Software/prepare-board.sh` - laptop-side: for each board on `adb devices`, pushes `Software/`, runs `setup ... --system` with sudo (BOARD_PASSWORD on stdin), copies the app to `~/ArduinoApps` (My Apps). Assumes App Lab already updated the board.
- `Software/golden-image.sh` - macOS: `prep` (clean + poweroff golden board), `capture` (`qdl read efi/rootfs/userdata` in EDL mode, builds `~/Downloads/unoq-flash/golden/`), `flash` (official `arduino-flasher-cli` with the golden folder), `finish <name>` (App Lab name + new machine-id on a clone).
- `Hardware/` - currently untracked in git. Holds only Gerber/drill exports and KiCad auto-backup zips for the UNO Q breakout, Qwiic LED board and microphone board; there are no live `.kicad_pro` / `.kicad_sch` / `.kicad_pcb` files. `.gitignore` excludes `*.gbr`, `*.drl`, `*.gbrjob` and the `*-backups/` dirs (note: the ignore entry is spelled `Micorphone-backups/` but the real dir is `Microphone-backups/`).

## Commands

There is no local build, lint or test tooling. Everything runs on the UNO Q itself:

```bash
sudo Software/setup-arduino-q-mic-applab.sh                  # full setup (idempotent), then: sudo reboot
sudo Software/setup-arduino-q-mic-applab.sh --verify-only    # preflight + checks, no changes
sudo Software/setup-arduino-q-mic-applab.sh --deploy-example # re-copy the app into App Lab examples
sudo Software/setup-arduino-q-mic-applab.sh --pull-images    # pre-pull keyword_spotting images only
sudo Software/setup-arduino-q-mic-applab.sh --patch-zephyr    # legacy arduino:zephyr 0.55.x header patch (not default)
BOARD_PASSWORD=... Software/prepare-board.sh                   # from the laptop, board updated by App Lab
Software/golden-image.sh prep|capture|flash|finish <name>       # golden image cloning (see README)
arduino-app-cli app start <app_path> ; arduino-app-cli app logs <app_path>   # run/test an app on the board
```

Steps 1 and 2 of the setup script are guarded by stamp files in `/var/lib/arduino-uno-q-setup/` (`alsa_setup_done`, `udev_setup_done`); delete one to force that step to re-run. Deploy and image pull always run (pull skips images already present). The script exits non-zero if any verify check fails. `APP_CLI_VERSION` is really the app-cli *assets* version (dir name under `/var/lib/arduino-app-cli/assets/`), which is also the `python-apps-base` tag; other image tags are parsed from `assets/<ver>/compose/arduino/keyword_spotting/brick_compose.yaml`.

Last verified on hardware 2026-11-05: arduino-app-cli 0.14.0, App Lab 0.11.0, assets 0.13.1, ei-models-runner 0.13.0, arduino:zephyr 0.90.0 (sketch builds without the zephyr patch).

## Board gotchas (measured)

- `adb shell` on the UNO Q exports `TMPDIR=/data/local/tmp`, which does not exist. arduino-cli / arduino-app-cli then fail with `stat /data/local/tmp` or `Some indexes could not be updated.` (also breaks `arduino-app-cli system update`). Always `export TMPDIR=/tmp` in adb sessions.
- After a big package upgrade `/` can drop to ~1 GB free; `sudo apt-get clean -y` + `arduino-app-cli system cleanup` (removes obsolete images only) recover it before pulling new images.
- Wi-Fi networks with a captive portal (registration per MAC) block the board; use a network without one.

## Architecture

Two halves talking over the Arduino RouterBridge RPC:

- `python/main.py` (Linux side, runs in an `arduino-app-cli` Docker container) - `KeywordSpotting.on_detect(<label>, ...)` -> `Bridge.call("<rpc_name>")`. Keyword label strings must match the Edge Impulse model labels exactly.
- `sketch/sketch.ino` (MCU side, `arduino:zephyr` core) - `Bridge.provide("<rpc_name>", fn)` handlers drive a seesaw NeoDriver (I2C `0x60`, on `Wire1` = Qwiic port, pin 15, 5 pixels) and play a heart animation on the onboard LED matrix (`heart_frames.h`).
- `app.yaml` declares the brick and pinned Arduino libraries; renaming an RPC requires changing both `main.py` and `sketch.ino`.

### Analog microphone workarounds (the non-obvious part)

These pieces are interdependent; changing one usually breaks the mic:

1. The Qualcomm LPASS/Q6ASM DSP and WirePlumber reset the `MultiMedia3` routing mixer to off on every PCM close. So `main.py` subclasses `ALSAMicrophone` (`_ArduinoQAnalogMic`) to re-apply the 9 amixer controls before every `_open_microphone()`. The same 9 controls are duplicated in the script's `/usr/local/bin/mic-uno-q-init.sh` (run at boot by `mic-uno-q.service`); keep the two lists in sync.
2. The mic must be opened with the explicit device `plughw:CARD=ArduinoImolaHPH,DEV=2`; the brick's default `usb:1` fails because the codec is on the SoC, not USB.
3. `arduino-app-cli`'s deploy validator requires a USB-looking device under `/dev/snd/by-id/usb-*`, so the script creates a fake `usb-Arduino_Analog_Microphone-00` symlink to `/dev/snd/pcmC0D2c` plus a udev rule to persist it.
4. `/etc/asound.conf` must NOT exist on the host; any content breaks PCM open inside the app containers. The script backs up and removes it.
5. `arduino:zephyr` 0.55.0's `variants/common/gpio_lowlevel_stm32.h` defines `portOutputRegister`/`portInputRegister` taking a pin instead of a port, which broke `Adafruit_BusIO` 1.16.1. The header is unchanged through 1.1.0, but with zephyr 0.90.0 + the pinned BusIO 1.17.4 the sketch compiles unpatched, so the fix is now opt-in (`--patch-zephyr`).
6. App Lab 0.10+ only indexes examples under category folders, so the app is deployed to `<examples>/inspirational/platform_unoq/uno-q-echoglow` (not the examples root). Examples dir is auto-detected under `/var/lib/arduino-app-cli` or `~/.local/share/arduino-app-cli`.

Known board state: after a factory reset the LPASS driver can get stuck in deferred probe and the `ArduinoImolaHPH` codec does not enumerate; only a full power cycle (not a reboot) clears it. The script's preflight detects this via dmesg.

## Docs

The top-level `README.md` covers workshop provisioning, tested versions and troubleshooting; `Software/uno-q-echoglow/README.md` is the app README shown in App Lab. Keep both in sync when the setup changes.
