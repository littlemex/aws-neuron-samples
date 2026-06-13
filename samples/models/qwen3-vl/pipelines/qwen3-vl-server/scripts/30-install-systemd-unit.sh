#!/usr/bin/env bash
set -euo pipefail

# Task: Install qwen3-vl.service systemd unit
# Description: Restart=always で常駐。 NEURON_RT_VISIBLE_CORES=${NEURON_CORES} (default 16-31, 16 cores 専有, trn2.48xlarge 前提)。
#              vllm serve は既存 cache を使うので 5-10 min で /health 200 になる想定。

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
ExecStart=/bin/bash ${SERVE_DIR}/start.sh --port ${PORT} --model-dir ${MODEL_DIR} --venv ${VENV} --cores ${NEURON_CORES}
Restart=always
RestartSec=15s
StandardOutput=journal
StandardError=journal
TimeoutStartSec=1800

[Install]
WantedBy=multi-user.target
EOF
echo '[OK] unit installed'
