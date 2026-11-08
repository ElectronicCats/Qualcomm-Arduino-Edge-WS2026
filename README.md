# UNO Q EchoGlow Workshop

<img src="Software/uno-q-echoglow/assets/docs_assets/EchoGlow.jpeg" alt="drawing" width="250" height="200"/>

The UNO Q EchoGlow is an AI-powered desktop light controlled by voice commands. It detects the keywords "Warmer-light", "Cooler-light", "Dimmer", and "Brighter" through an analog microphone connected directly to the Arduino UNO Q, and controls a NeoPixel strip connected via the onboard Qwiic port. The keyword model is trained on Edge Impulse's platform during the workshop and deployed to the Arduino UNO Q.

This setup uses the analog microphone input of the Arduino UNO Q instead of a USB microphone (unlike the standard keyword-spotting example), so each board needs a one-time configuration before launching the app.

Project page: [https://hackaday.io/project/205386-arduino-uno-q-echoglow](https://hackaday.io/project/205386-arduino-uno-q-echoglow)

## Repository contents

| Path | What it is |
|---|---|
| `Software/uno-q-echoglow/` | The Arduino App Lab app (Python + sketch). See its [README](Software/uno-q-echoglow/README.md). |
| `Software/setup-arduino-q-mic-applab.sh` | Mic setup, runs **on the board** as root. |
| `Software/prepare-board.sh` | Runs **on a laptop**: applies the mic setup and installs EchoGlow on a board connected over USB. |
| `Software/golden-image.sh` | Runs **on a Mac**: captures one finished board as a "golden image" and flashes it onto other boards. |

## Hardware

![Hardware setup](Software/uno-q-echoglow/assets/docs_assets/hardware-setup.jpeg)

- [Arduino UNO Q](https://store.arduino.cc/products/uno-q)
- SupplyFrame analog microphone board, connected to the analog mic input
- SupplyFrame NeoDriver I2C board (address `0x60`) with a NeoPixel strip (up to 5 pixels), connected to the **Qwiic** port

Only connect or disconnect the mic and NeoDriver boards while the UNO Q is powered off.

## Tested versions

Tested on 2026-11-07:

| Component | Version |
|---|---|
| Debian image (official, `arduino-flasher-cli`) | 20260528-558, kernel 7.0.0 |
| arduino-app-lab (on board) | 0.12.0 |
| arduino-app-cli | 0.14.1 |
| arduino-unoq | 0.2.1 |
| arduino:zephyr core | 0.90.0 and 1.1.0 (sketch builds on both, no core patch needed) |

## Preparing many boards: golden image (recommended)

Set up one board completely, copy its storage, and flash that copy onto every other board. Each clone boots already updated, with the mic configured, EchoGlow in My Apps, the Wi-Fi saved and the password set. No App Lab update and no setup script per board.

Requirements on the Mac: [`arduino-flasher-cli`](https://github.com/arduino/arduino-flasher-cli/releases) and the official image extracted in `~/Downloads/unoq-flash/` (`arduino-flasher-cli download unoq`, then extract), `qdl` (`brew install qdl`), `adb` (`brew install --cask android-platform-tools`), about 40 GB free. Close App Lab during all steps.

**Entering EDL (flash) mode:** unplug the board, short the two pins in the rightmost column of the **JCTL** header, `GND` (upper row) and `USB_BOOT` (lower row), with a jumper, then plug the board into the computer directly (no hub). See [Flash a Linux Image](https://docs.arduino.cc/software/app-lab/configure/flash/).

### 1. Make the golden board (once)

1. Flash the official image: `./arduino-flasher-cli flash unoq ./image -y` (board in EDL mode). Unplug, remove the jumper, plug in.
2. In App Lab: first-time setup (Wi-Fi, password, name) and accept every update it offers.
3. Close App Lab and run `BOARD_PASSWORD=<password> Software/prepare-board.sh` (mic setup + EchoGlow in My Apps).

### 2. Capture it (once)

```bash
BOARD_PASSWORD=<password> Software/golden-image.sh prep   # board booted, on USB: cleans and powers off
# put the board in EDL mode, then:
Software/golden-image.sh capture                          # reads efi, rootfs, userdata (~8 min)
```

The golden image is written to `~/Downloads/unoq-flash/golden/` (about 15 GB).

### 3. Clone every other board

```bash
Software/golden-image.sh flash                                       # board in EDL mode (~13-15 min)
# unplug, remove the jumper, plug in, wait ~1 min, then:
BOARD_PASSWORD=<password> Software/golden-image.sh finish echoglow-01  # unique name + new machine-id
```

Use a different name for every board: clones start with the golden board's name and machine-id.

Measured: capture 472 s (~31 MB/s); clone flash 777 s and 904 s (rootfs ~21 MB/s, userdata 11-16 MB/s). One flash failed with `USB write failed` while other USB traffic was running; retrying with nothing else on USB worked.

To flash from other computers (Windows, Intel Mac), copy the `golden/` folder together with the matching `arduino-flasher-cli` build and `adb` (exFAT drive, one file is 10.7 GB) and run the same `flash unoq <folder> -y` command.

## Preparing a single board without cloning

1. Connect the board in App Lab, finish its setup and accept the update.
2. Close App Lab and run:

   ```bash
   BOARD_PASSWORD=<password> Software/prepare-board.sh
   ```

   It copies `Software/` to the board, runs `sudo setup-arduino-q-mic-applab.sh --system` and installs EchoGlow under App Lab **My Apps**.

Or directly on the board (terminal on the UNO Q):

```bash
git clone https://github.com/ElectronicCats/Qualcomm-Arduino-Edge-WS2026
cd Qualcomm-Arduino-Edge-WS2026
sudo Software/setup-arduino-q-mic-applab.sh
```

| Command | What it does |
|---|---|
| `sudo Software/setup-arduino-q-mic-applab.sh` | Full setup (mic, udev, example, Docker images) + verification |
| `sudo Software/setup-arduino-q-mic-applab.sh --system` | Same without Docker images |
| `sudo Software/setup-arduino-q-mic-applab.sh --verify-only` | Checks only, no changes |
| `sudo Software/setup-arduino-q-mic-applab.sh --deploy-example` | Re-copy the app into the App Lab examples folder |
| `sudo Software/setup-arduino-q-mic-applab.sh --pull-images` | Only pre-download the Docker images |
| `sudo Software/setup-arduino-q-mic-applab.sh --patch-zephyr` | Legacy fix for arduino:zephyr 0.55.x (not needed on 0.90.0 / 1.1.0) |

## What the mic setup does

The UNO Q microphone codec is part of the Qualcomm QRB2210 SoC, not a USB device, so App Lab's default microphone handling does not find it. The setup script:

1. **ALSA mixer:** installs `mic-uno-q.service`, which applies the 9 mixer controls that route the analog mic at boot. A leftover `/etc/asound.conf` from older versions of this script is backed up and removed.
2. **Device check:** `arduino-app-cli` only starts apps that need a microphone when `/dev/snd/by-id/` is not empty. The script creates `/dev/snd/by-id/usb-Arduino_Analog_Microphone-00` (pointing to the codec capture device) and a udev rule that recreates it on every boot.
3. **Example:** copies the app into the App Lab examples folder.

The app itself handles the rest: the Qualcomm audio DSP and WirePlumber turn the mic routing off whenever a capture session closes, so `python/main.py` re-applies the mixer controls every time it opens the microphone and opens it by explicit name (`plughw:CARD=ArduinoImolaHPH,DEV=2`).

## Running the app

1. Open **Arduino App Lab** and connect to the board.
2. Open **UNO Q EchoGlow** from **My Apps** and click **Play**. (App Lab's Examples screen only lists apps from its own index, so a copy placed in the examples folder may not appear there.)
3. Deploy the keyword model trained in the workshop. The `keyword_spotting` brick's default model only detects "Hey Arduino", which this app does not react to.
4. Say one of the commands:

| Keyword | Action |
|---|---|
| **Warmer-light** | NeoPixels to warm white (RGB 255, 194, 138) |
| **Cooler-light** | NeoPixels to cool white (RGB 144, 213, 255) |
| **Brighter** | Brightness up 40% |
| **Dimmer** | Brightness down 40% |

## Troubleshooting

- **`ArduinoImolaHPH codec not detected` / `no microphone device found`:** after a factory reset or an abrupt power loss the audio driver can stay stuck (`dmesg`: `Failed to get clk 'audio'`, `deferred probe pending`); a reboot does not fix it. Unplug power, wait 5 seconds, plug back in.
- **Sketch fails to link (`undefined reference`) after a board reset during a build:** the interrupted build left empty object files in the app cache. Run `arduino-app-cli app clean-cache uno-q-echoglow`.
- **Commands over `adb shell` fail with `stat /data/local/tmp` or `Some indexes could not be updated.`:** adb sets `TMPDIR=/data/local/tmp`, which does not exist on the board. Run `export TMPDIR=/tmp` first. App Lab itself is not affected.
- **Flasher waits forever on `Waiting for EDL device`:** the jumper was not in place when the board was plugged in, or App Lab / adb is holding the USB device. Quit App Lab, run `adb kill-server`, re-plug with the jumper.
- **Wi-Fi with a captive portal** (registration page): the board cannot complete it by itself; use a network without a portal.
