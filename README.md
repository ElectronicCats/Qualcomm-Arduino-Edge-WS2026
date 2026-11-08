# UNO Q EchoGlow Workshop

<img src="Software/uno-q-echoglow/assets/docs_assets/EchoGlow.jpeg" alt="drawing" width="250" height="200"/>

The UNO Q EchoGlow is an AI-powered desktop light controlled by voice commands. It detects the keywords "Warmer-light", "Cooler-light", "Dimmer", and "Brighter" through an analog microphone connected directly to the Arduino UNO Q, and controls a NeoPixel strip connected via the onboard Qwiic port. The keyword model is trained on Edge Impulse's platform during the workshop and deployed to the Arduino UNO Q.

This setup uses the analog microphone input of the Arduino UNO Q instead of a USB microphone (unlike the standard keyword-spotting example), so the board needs a one-time configuration before launching the app.

Project page: [https://hackaday.io/project/205386-arduino-uno-q-echoglow](https://hackaday.io/project/205386-arduino-uno-q-echoglow)

## Bricks Used

- `keyword_spotting`: detects sound patterns and triggers an event when a keyword is matched.

## Hardware and Software Requirements

![Hardware setup](Software/uno-q-echoglow/assets/docs_assets/hardware-setup.jpeg)

### Hardware

- [Arduino UNO Q](https://store.arduino.cc/products/uno-q)
- SupplyFrame analog microphone board, connected to the analog mic input
- SupplyFrame NeoDriver I2C board (address `0x60`) with a NeoPixel strip (up to 5 pixels), connected to the **Qwiic** port

Connect or disconnect the mic and NeoDriver boards only while the UNO Q is powered off.

### Software

- Arduino App Lab (tested with App Lab 0.12.0 on the board, arduino-app-cli 0.14.1)
- One-time board setup, see [Setup](#setup) below

## Setup

> **Workshop boards are already set up.** Do this only on your own board.

> **Required once per board.** It configures the analog microphone (ALSA mixer service, the `/dev/snd/by-id` entry that App Lab needs to start an app with a microphone) and installs EchoGlow in App Lab **My Apps**.

1. Connect the board in Arduino App Lab, finish its first-time setup and accept any update it offers.
2. Open a terminal on the UNO Q and run:

   ```bash
   git clone https://github.com/ElectronicCats/Qualcomm-Arduino-Edge-WS2026
   cd Qualcomm-Arduino-Edge-WS2026
   sudo Software/setup-arduino-q-mic-applab.sh
   ```

The script ends with a list of checks and exits with 0 only when all of them pass. To re-check later: `sudo Software/setup-arduino-q-mic-applab.sh --verify-only`. Running it again re-installs EchoGlow in My Apps (changes made to that copy are replaced).

> **Note:** with this setup only the analog microphone is used by the app (no USB microphone). To fully revert, reflash the UNO Q.

## How to Use the Example

### Hardware Setup

1. Connect the analog microphone board to the analog mic input of the Arduino UNO Q.
2. Connect the SupplyFrame NeoDriver I2C board to the **Qwiic port** on the Arduino UNO Q.
3. Connect a NeoPixel strip to the NeoDriver (up to 5 pixels supported out of the box).

### Launch the App

1. Open **Arduino App Lab** and connect to the board.
2. Open **UNO Q EchoGlow** from **My Apps**.
3. Add the keyword model you trained in Edge Impulse during the workshop. The brick's default model only detects "Hey Arduino", which this app does not react to.
4. Click the **Play** button in the top right corner and wait for the app to launch.
5. Say one of the voice commands into the microphone.

### Voice Commands

| Keyword | Action |
|---|---|
| **Warmer-light** | Sets NeoPixel color to warm white (RGB 255, 194, 138) |
| **Cooler-light** | Sets NeoPixel color to cool white (RGB 144, 213, 255) |
| **Brighter** | Increases brightness by 40% |
| **Dimmer** | Decreases brightness by 40% |

### How it Works

The `keyword_spotting` Brick continuously monitors the analog microphone input. When a keyword is detected, it calls the microcontroller via the Bridge, which adjusts the NeoPixel strip and plays a heart animation on the LED matrix. The NeoPixel starts at neutral white (RGB 255, 255, 255) at boot.

The UNO Q microphone codec is part of the Qualcomm QRB2210 SoC, not a USB device, so App Lab's default microphone handling does not find it. The setup script installs `mic-uno-q.service` (applies the mic mixer controls at boot) and a `/dev/snd/by-id/usb-Arduino_Analog_Microphone-00` entry with a udev rule so App Lab accepts the codec. The Qualcomm audio DSP turns the mic routing off whenever a capture session closes, so `python/main.py` re-applies the mixer controls every time it opens the microphone and opens it by explicit name (`plughw:CARD=ArduinoImolaHPH,DEV=2`).

See the [app README](Software/uno-q-echoglow/README.md) for the code walkthrough.

## Troubleshooting

- **`ArduinoImolaHPH codec not detected` or `no microphone device found`:** the audio driver can get stuck after a factory reset or an abrupt power loss; a reboot does not fix it. Unplug power, wait 5 seconds, plug back in.
- **The sketch fails to build with `undefined reference` after the board lost power during a build:** clear the app's build cache from a terminal on the board: `arduino-app-cli app clean-cache uno-q-echoglow`, then press Play again.
- **EchoGlow does not appear in App Lab:** look under **My Apps**, not Examples. If it is missing, run `sudo Software/setup-arduino-q-mic-applab.sh --deploy-example`.
