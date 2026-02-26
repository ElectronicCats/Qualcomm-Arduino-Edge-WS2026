#!/bin/bash
# =============================================================================
# Setup Micrófono Analógico — Arduino UNO Q (QRB2210 / pm4125)
# =============================================================================
# Ejecutar como root o con sudo
# Uso: sudo bash setup-mic-uno-q.sh
# =============================================================================

set -e

echo ""
echo "=============================================="
echo " Setup Micrófono Analógico - Arduino UNO Q"
echo "=============================================="
echo ""

# ------------------------------------------------------------------------------
# 1. Configurar mixer ALSA
# ------------------------------------------------------------------------------
echo "[1/4] Configurando ALSA mixer..."

amixer -c 0 cset name='TX DEC0 MUX'                         'SWR_MIC'
amixer -c 0 cset name='TX SMIC MUX0'                        'SWR_MIC1'
amixer -c 0 cset name='ADC2 MUX'                            'INP2'
amixer -c 0 cset name='ADC2 Switch'                          1
amixer -c 0 cset name='ADC2 Volume'                          8
amixer -c 0 cset name='ADC2_MIXER Switch'                    1
amixer -c 0 cset name='TX_DEC0 Volume'                       82
amixer -c 0 cset name='TX_AIF1_CAP Mixer DEC0'               1
amixer -c 0 cset name='MultiMedia3 Mixer TX_CODEC_DMA_TX_3'  1

echo "    OK — Mixer configurado"

# ------------------------------------------------------------------------------
# 2. Crear /etc/asound.conf — redirige default capture a hw:0,2
# ------------------------------------------------------------------------------
echo "[2/4] Configurando /etc/asound.conf..."

cat > /etc/asound.conf << 'EOF'
# Redirigir captura default hacia hw:0,2 (MultiMedia3 - mic analógico)
# Arduino UNO Q — QRB2210 / pm4125 codec
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

echo "    OK — /etc/asound.conf creado"

# ------------------------------------------------------------------------------
# 3. Crear wrapper de sox — reemplaza hw:0,0 por default (para Edge Impulse)
# ------------------------------------------------------------------------------
echo "[3/4] Creando wrapper de sox..."

cat > /usr/local/bin/sox << 'EOF'
#!/bin/bash
# Wrapper sox — reemplaza hw:0,0 por default (Arduino UNO Q)
ARGS=("$@")
for i in "${!ARGS[@]}"; do
    if [ "${ARGS[$i]}" = "hw:0,0" ]; then
        ARGS[$i]="default"
    fi
done
exec /usr/bin/sox "${ARGS[@]}"
EOF

chmod +x /usr/local/bin/sox
echo "    OK — Wrapper sox en /usr/local/bin/sox"

# ------------------------------------------------------------------------------
# 4. Crear servicio systemd — configura mixer en cada arranque
# ------------------------------------------------------------------------------
echo "[4/4] Instalando servicio systemd..."

cat > /usr/local/bin/mic-uno-q-init.sh << 'EOF'
#!/bin/bash
# Inicializar mixer de micrófono analógico — Arduino UNO Q
sleep 5
amixer -c 0 cset name='TX DEC0 MUX'                         'SWR_MIC'
amixer -c 0 cset name='TX SMIC MUX0'                        'SWR_MIC1'
amixer -c 0 cset name='ADC2 MUX'                            'INP2'
amixer -c 0 cset name='ADC2 Switch'                          1
amixer -c 0 cset name='ADC2 Volume'                          8
amixer -c 0 cset name='ADC2_MIXER Switch'                    1
amixer -c 0 cset name='TX_DEC0 Volume'                       82
amixer -c 0 cset name='TX_AIF1_CAP Mixer DEC0'               1
amixer -c 0 cset name='MultiMedia3 Mixer TX_CODEC_DMA_TX_3'  1
logger "mic-uno-q: mixer configurado OK"
EOF

chmod +x /usr/local/bin/mic-uno-q-init.sh

cat > /etc/systemd/system/mic-uno-q.service << 'EOF'
[Unit]
Description=Configurar micrófono analógico Arduino UNO Q
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
systemctl enable mic-uno-q.service
systemctl start mic-uno-q.service

echo "    OK — Servicio mic-uno-q habilitado y activo"

# ------------------------------------------------------------------------------
# Verificación final
# ------------------------------------------------------------------------------
echo ""
echo "----------------------------------------------"
echo " Verificando captura de audio..."
echo " Habla cerca del micrófono durante 2 segundos"
echo "----------------------------------------------"
sleep 1

sox -t alsa default -t wav /tmp/mic_test.wav trim 0 2 2>/dev/null

RMS=$(python3 -c "
import wave,struct,math
with wave.open('/tmp/mic_test.wav') as f:
    d=f.readframes(f.getnframes())
s=struct.unpack('<'+'h'*(len(d)//2),d)
print(int(math.sqrt(sum(x*x for x in s)/len(s))))
" 2>/dev/null)

echo ""
if [ "$RMS" -gt 200 ] 2>/dev/null; then
    echo "  RMS=$RMS — ✅ Micrófono funcionando correctamente"
else
    echo "  RMS=$RMS — ⚠️  Señal baja. Verifica el cableado físico:"
    echo "     MIC+    → JMISC Pin 29"
    echo "     MICBIAS → 1.8V del board (NO usar pin 33)"
    echo "     MIC-    → GND"
fi

echo ""
echo "=============================================="
echo " Setup completo."
echo " Para Edge Impulse: edge-impulse-linux --disable-camera"
echo " Para grabar:       arecord -D hw:0,2 -f S16_LE -r 16000 -c 1 -d 5 out.wav"
echo "=============================================="
echo ""
