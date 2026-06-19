#!/usr/bin/env bash
set -euo pipefail

# Install qwen3-vl.service systemd unit.
# Runs permanently via Restart=always. NEURON_RT_VISIBLE_CORES pins NeuronCores
# 16-31 (TP=16, trn2.48xlarge). NEURON_COMPILE_CACHE_URL points at the
# EFS-backed compile cache so vllm reuses compiled artifacts after instance
# replacement (avoids ~60 min cold recompile). TimeoutStartSec=3900 covers the
# worst-case cold compile path.

cat > /etc/systemd/system/qwen3-vl.service <<EOF
[Unit]
Description=Qwen3-VL-8B-Instruct vLLM Neuron server (OpenAI compatible)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVE_USER}
WorkingDirectory=${SERVE_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=PORT=${PORT}
Environment=MODEL_DIR=${MODEL_DIR}
Environment=VENV=${VENV}
Environment=NEURON_CORES=${NEURON_CORES}
Environment=LOG_DIR=${SERVE_DIR}/logs
Environment=NEURON_COMPILE_CACHE_URL=${COMPILE_CACHE}
ExecStart=/bin/bash ${SERVE_DIR}/start.sh --port ${PORT} --model-dir ${MODEL_DIR} --venv ${VENV} --cores ${NEURON_CORES}
Restart=always
RestartSec=15s
StandardOutput=journal
StandardError=journal
TimeoutStartSec=3900

[Install]
WantedBy=multi-user.target
EOF
echo '[OK] unit installed'
