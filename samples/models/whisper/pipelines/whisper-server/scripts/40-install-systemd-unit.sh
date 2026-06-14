#!/usr/bin/env bash
set -euo pipefail

# Restart=always で常駐。0.0.0.0:${PORT} で listen。
# NEURON_RT_VISIBLE_CORES=${NEURON_CORE} で 1 core 専有。
# 言語は WHISPER_LANGUAGE 環境変数で切替 (ja|en|auto|none)。

cat > /etc/systemd/system/whisper-server.service <<EOF
[Unit]
Description=Whisper-large-v3 Neuron server (HTTP /transcribe + WebSocket /whisper-neuron/ws)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVE_USER}
WorkingDirectory=${SERVE_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=PATH=${VENV}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=NEURON_RT_VISIBLE_CORES=${NEURON_CORE}
Environment=NEURON_RT_NUM_CORES=1
Environment=PORT=${PORT}
Environment=PATH_PREFIX=${PATH_PREFIX}
Environment=MODEL_ID=${MODEL_ID}
Environment=MODEL_DIR=${MODEL_DIR}
Environment=WHISPER_LANGUAGE=${WHISPER_LANGUAGE}
ExecStart=${VENV}/bin/python ${SERVE_DIR}/whisper_server.py
Restart=always
RestartSec=10s
StandardOutput=journal
StandardError=journal
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
EOF
echo '[OK] unit installed'
