#!/bin/bash
# =============================================================================
# mic.sh — Grabar audio con micrófono analógico en Arduino UNO Q
# Uso: ./mic.sh [segundos] [archivo.wav]
# Ejemplo: ./mic.sh 5 grabacion.wav
# =============================================================================

# Verificar mixer activo
amixer -c 0 cget name='MultiMedia3 Mixer TX_CODEC_DMA_TX_3' 2>/dev/null | grep -q 'values=on' || {
    echo "Configurando mixer..."
    amixer -c 0 cset name='TX DEC0 MUX'                         'SWR_MIC' >/dev/null
    amixer -c 0 cset name='TX SMIC MUX0'                        'SWR_MIC1' >/dev/null
    amixer -c 0 cset name='ADC2 MUX'                            'INP2' >/dev/null
    amixer -c 0 cset name='ADC2 Switch'                          1 >/dev/null
    amixer -c 0 cset name='ADC2 Volume'                          8 >/dev/null
    amixer -c 0 cset name='ADC2_MIXER Switch'                    1 >/dev/null
    amixer -c 0 cset name='TX_DEC0 Volume'                       82 >/dev/null
    amixer -c 0 cset name='TX_AIF1_CAP Mixer DEC0'               1 >/dev/null
    amixer -c 0 cset name='MultiMedia3 Mixer TX_CODEC_DMA_TX_3'  1 >/dev/null
}

DURATION="${1:-5}"
OUTPUT="${2:-output.wav}"

echo "Grabando ${DURATION}s → ${OUTPUT}"
arecord -D hw:0,2 -f S16_LE -r 16000 -c 1 -d "$DURATION" "$OUTPUT"
echo "Listo: $OUTPUT"
