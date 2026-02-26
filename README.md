# Micrófono Analógico — Arduino UNO Q (QRB2210)

## Cableado físico (CRÍTICO)

```
Micrófono electret (3 cables)     JMISC / Board
─────────────────────────────     ─────────────
MIC+  (señal)           ──────→   Pin 29 (JMISC)
MICBIAS (alimentación)  ──────→   1.8V del board  ← NO usar pin 33
GND                     ──────→   GND
```

> ⚠️ El pin 33 del JMISC (MICBIAS) está definido en el device tree pero
> no entrega voltaje físicamente. Conectar el cápsulo directamente al
> riel de 1.8V del board.

---

## Instalación en placa nueva

```bash
# Copiar el script al board (desde tu PC)
scp setup-mic-uno-q.sh arduino@<IP_DEL_BOARD>:~

# En el board
sudo bash setup-mic-uno-q.sh
```

El script hace todo automáticamente:
- Configura los controles ALSA mixer
- Crea `/etc/asound.conf` (redirige default → hw:0,2)
- Crea wrapper de sox en `/usr/local/bin/sox`
- Instala servicio systemd `mic-uno-q` (configura mixer en cada boot)
- Verifica que el micrófono funciona

---

## Uso después del setup

### Grabar audio
```bash
# Con el script incluido
./mic.sh 5 grabacion.wav

# Directo con arecord
arecord -D hw:0,2 -f S16_LE -r 16000 -c 1 -d 5 output.wav
```

### Edge Impulse
```bash
edge-impulse-linux --disable-camera
```

---

## Path de audio (referencia técnica)

```
JMISC Pin 29
    │
    ↓
AMIC2 (pm4125 codec)
    │
    ↓
MIC BIAS2 (1.8V — DAPM widget, activo automáticamente)
    │
    ↓
ADC2 → ADC2 MUX (INP2)
    │
    ↓
SoundWire → SWR_MIC1
    │
    ↓
TX Macro → TX DEC0 (SWR_MIC)
    │
    ↓
TX_AIF1_CAP DEC0
    │
    ↓
DMA TX_CODEC_DMA_TX_3
    │
    ↓
MultiMedia3 (hw:0,2)
```

---

## Controles ALSA (valores óptimos)

| Control | Valor |
|---|---|
| TX DEC0 MUX | SWR_MIC |
| TX SMIC MUX0 | SWR_MIC1 |
| ADC2 MUX | INP2 |
| ADC2 Switch | on |
| ADC2 Volume | 8 (+1.75dB max) |
| ADC2_MIXER Switch | on |
| TX_DEC0 Volume | 82 (~-3dB) |
| TX_AIF1_CAP Mixer DEC0 | on |
| MultiMedia3 Mixer TX_CODEC_DMA_TX_3 | on |

---

## Parámetros de captura

| Parámetro | Valor |
|---|---|
| Device ALSA | hw:0,2 (MultiMedia3) |
| Formato | S16_LE |
| Sample rate | 16000 Hz |
| Canales | 1 (mono) |

---

## Verificación rápida

```bash
# RMS noise floor (sin voz): ~200-300
# RMS con voz normal: ~1000-3000
# Si RMS con voz < 500: revisar cableado físico

arecord -D hw:0,2 -f S16_LE -r 16000 -c 1 -d 2 /tmp/test.wav 2>/dev/null
python3 -c "
import wave,struct,math
with wave.open('/tmp/test.wav') as f:
    d=f.readframes(f.getnframes())
s=struct.unpack('<'+'h'*(len(d)//2),d)
print(f'RMS={int(math.sqrt(sum(x*x for x in s)/len(s)))}')
"
```
