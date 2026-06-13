#!/usr/bin/env bash
set -euo pipefail

# Task: 40-install-systemd-unit
# Description: Restart=always で常駐。 NEURON_RT_VISIBLE_CORES=${NEURON_CORES} で 32 cores 専有 (TP=16 DP=2 world_size=32)。
#              port ${PORT} で listen。 PATH_PREFIX=${PATH_PREFIX} (FastAPI に /qwen-image-edit/health 等の prefix endpoint も載る)。

cat > /etc/systemd/system/qwen-image-edit.service <<EOF
[Unit]
Description=Qwen-Image-Edit-2511 Neuron server (FastAPI multipart /infer)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVE_USER}
WorkingDirectory=${SERVE_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONPATH=${SERVE_DIR}
Environment=NEURON_RT_VISIBLE_CORES=${NEURON_CORES}
Environment=NEURON_RT_NUM_CORES=${WORLD_SIZE}
Environment=PORT=${PORT}
Environment=HOST=${HOST}
Environment=COMPILED_DIR=${COMPILED_MODELS_DIR}
Environment=HEIGHT=${HEIGHT}
Environment=WIDTH=${WIDTH}
Environment=PATCH_MULT=${PATCH_MULTIPLIER}
Environment=NEURON_CORES=${NEURON_CORES}
Environment=WORLD_SIZE=${WORLD_SIZE}
Environment=PATH_PREFIX=${PATH_PREFIX}
Environment=HUGGINGFACE_CACHE_DIR=${HF_CACHE_DIR}
Environment=HF_HOME=${HF_HOME_DIR}
Environment=TRANSFORMERS_CACHE=${HF_CACHE_DIR}
Environment=VTON_S3_MODELS_URI=${VTON_S3_MODELS_URI}
Environment=VTON_S3_MODELS_REGION=${VTON_S3_MODELS_REGION}
Environment=LOG_DIR=${SERVE_DIR}/logs
ExecStart=/bin/bash ${SERVE_DIR}/start.sh --port ${PORT} --host ${HOST} --compiled-dir ${COMPILED_MODELS_DIR} --height ${HEIGHT} --width ${WIDTH} --cores ${NEURON_CORES} --world-size ${WORLD_SIZE} --serve-py ${SERVE_DIR}/serve.py
Restart=always
RestartSec=15s
StandardOutput=journal
StandardError=journal
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF

echo "[OK] unit installed"
