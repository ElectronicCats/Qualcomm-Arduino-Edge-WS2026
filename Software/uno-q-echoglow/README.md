# UNO Q EchoGlow

![EchoGlow](assets/docs_assets/EchoGlow.jpeg)

The UNO Q EchoGlow is an AI-powered desktop light controlled by voice commands. It detects the keywords "Warmer-light", "Cooler-light", "Dimmer", and "Brighter" through an analog microphone connected directly to the Arduino UNO Q, and controls a NeoPixel strip connected via the onboard Qwiic port. These commands are trained on Edge Impulse's platform and uploaded to the Arduino UNO Q inside the EchoGlow.

This app uses the analog microphone input of the Arduino UNO Q instead of a USB microphone (unlike the standard keyword-spotting example), so the board needs a one-time configuration before launching it.

Project page: [https://hackaday.io/project/205386-arduino-uno-q-echoglow](https://hackaday.io/project/205386-arduino-uno-q-echoglow)

## Bricks Used

- `keyword_spotting`: detects sound patterns and triggers an event when a keyword is matched.

## Hardware and Software Requirements

![Hardware setup](assets/docs_assets/hardware-setup.jpeg)

### Hardware

- [Arduino UNO Q](https://store.arduino.cc/products/uno-q)
- SupplyFrame analog microphone board (connected to the analog mic input)
- SupplyFrame NeoDriver I2C board (address `0x60`) with NeoPixel strip, connected to the Qwiic port

### Software

- Arduino App Lab (tested with App Lab 0.11.0 / arduino-app-cli 0.14.0 / arduino:zephyr 0.90.0)
- One-time board setup, see [Setup](#setup) below

## Setup

> **Required once per board.** It configures the ALSA mixer at boot, creates the `/dev/snd/by-id` entry that `arduino-app-cli` needs before it starts an app with a microphone, installs this app in App Lab **My Apps**, and pre-downloads the Docker images.

On the Arduino UNO Q:

```bash
git clone https://github.com/ElectronicCats/Qualcomm-Arduino-Edge-WS2026
cd Qualcomm-Arduino-Edge-WS2026
sudo Software/setup-arduino-q-mic-applab.sh
```

The script ends with a list of checks and exits with 0 only when all of them pass. To re-check a board later: `sudo Software/setup-arduino-q-mic-applab.sh --verify-only`. To re-deploy only this example: `sudo Software/setup-arduino-q-mic-applab.sh --deploy-example`.

> **Note:** with this setup only the analog microphone is used by the app (no USB microphone). To fully revert, reflash/format the UNO Q.

## How to Use the Example

### Hardware Setup

1. Connect the analog microphone board to the analog mic input of the Arduino UNO Q.
2. Connect the SupplyFrame NeoDriver I2C board to the **Qwiic port** on the Arduino UNO Q.
3. Connect a NeoPixel strip to the NeoDriver (up to 5 pixels supported out of the box).

### Launch the App

1. Open **Arduino App Lab** and connect to the board.
2. Open **UNO Q EchoGlow** from **My Apps**, add the keyword model you trained in the workshop (the brick's default model only detects "Hey Arduino"), and click the **Play** button in the top right corner.
3. Wait for the app to launch.
4. Say one of the voice commands into the microphone.

### Voice Commands

| Keyword | Action |
|---|---|
| **Warmer-light** | Sets NeoPixel color to warm white (RGB 255, 194, 138) |
| **Cooler-light** | Sets NeoPixel color to cool white (RGB 144, 213, 255) |
| **Brighter** | Increases brightness by 40% |
| **Dimmer** | Decreases brightness by 40% |

### How it Works

The `keyword_spotting` Brick continuously monitors the analog microphone input. When a keyword is detected, it calls the microcontroller via the Bridge, which adjusts the NeoPixel strip and plays a heart animation on the LED matrix. The NeoPixel starts at neutral white (RGB 255, 255, 255) at boot.

#### Why a setup script is needed

The Arduino UNO Q codec is exposed by ALSA but is not a USB device, so `arduino-app-cli`'s microphone check (which looks for entries under `/dev/snd/by-id/`) does not see it. The setup script:

- Installs `mic-uno-q.service`, which applies the mixer setup at boot, and removes a leftover `/etc/asound.conf` from older versions of the script (backup kept).
- Creates a `/dev/snd/by-id/usb-Arduino_Analog_Microphone-00` symlink (with a persistent udev rule) so `arduino-app-cli` accepts the codec.
- Copies this app to `examples/inspirational/platform_unoq/`, where App Lab lists UNO Q examples.
- Pre-pulls the Docker images of the `keyword_spotting` brick for the installed App Lab version.

### Understanding the Code

**Python side (`python/main.py`):**

- `_ArduinoQAnalogMic(ALSAMicrophone)`: re-applies the 9 ALSA mixer controls before every microphone open, because the Qualcomm audio DSP and WirePlumber switch the mic routing off whenever a capture session closes.
- `mic = _ArduinoQAnalogMic(device="plughw:CARD=ArduinoImolaHPH,DEV=2", shared=False)`: opens the analog codec directly (the default `usb:1` device is for USB mics and fails here).
- `spotter = KeywordSpotting(mic=mic)`: uses that microphone instead of the default.
- `spotter.on_detect("Warmer-light", ...)`: registers a callback for each keyword.
- `Bridge.call("warmer_light")`: notifies the microcontroller which keyword was detected.

**Microcontroller side (`sketch/sketch.ino`):**

- `seesaw_NeoPixel strip(..., &Wire1)`: the NeoDriver is on `Wire1`, which maps to the Qwiic port on the UNO Q.
- `Bridge.provide("warmer_light", warmer_light)`: registers the handler called by the Python side.
- `warmer_light()` / `cooler_light()`: set the NeoPixel color to warm or cool white.
- `brighter()` / `dimmer()`: increase or decrease the global brightness by 40%.
