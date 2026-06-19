#!/usr/bin/env bash
set -euo pipefail

# Task: Install xttsv2-server.service systemd unit (docker-managed)
# The unit launches the runtime image with `docker run --rm --device /dev/neuron0`.
# Restart=always covers transient issues. TimeoutStartSec=900 covers warm-up
# while the model loads ~3GB of NEFF.
#
# NOTE: ${VAR} inside the heredoc is intentional — the unit file must contain
# the resolved values so that systemd sees the actual paths/ports at runtime,
# not the literal variable names.

cat > /etc/systemd/system/xttsv2-server.service <<EOF
[Unit]
Description=XTTSv2 NxD Inference server (DLC, HTTP /synthesize)
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=simple
User=root
Group=root
ExecStartPre=-/usr/bin/docker rm -f xttsv2-server
ExecStart=/usr/bin/docker run --rm \\
  --name xttsv2-server \\
  --device /dev/neuron0 \\
  --shm-size 8g \\
  -p ${PORT}:${PORT} \\
  -e PORT=${PORT} \\
  -e PYTHONUNBUFFERED=1 \\
  -e NEURON_RT_VISIBLE_CORES=${NEURON_CORES} \\
  -e NEURON_RT_NUM_CORES=${TP_DEGREE} \\
  -e NEURON_RT_VIRTUAL_CORE_SIZE=2 \\
  -e NEURON_LOGICAL_NC_CONFIG=2 \\
  -e COMPILED_MODEL_PATH=${COMPILED_MODEL_PATH} \\
  -e XTTS_MODEL_DIR=${XTTS_MODEL_DIR} \\
  -e XTTSV2_VOICES_DIR=${XTTSV2_VOICES_DIR} \\
  -e XTTSV2_DEFAULT_VOICE=${XTTSV2_DEFAULT_VOICE} \\
  -e XTTSV2_LANGUAGE=${XTTSV2_LANGUAGE} \\
  -e TP_DEGREE=${TP_DEGREE} \\
  -v /models:/models \\
  -v ${SERVE_DIR}:/app:ro \\
  -w /app \\
  --entrypoint /bin/bash \\
  ${RUNTIME_IMAGE} \\
  -lc 'exec uvicorn xttsv2_server:app --host 0.0.0.0 --port ${PORT} --proxy-headers --no-server-header --timeout-keep-alive 75'
ExecStop=/usr/bin/docker stop -t 30 xttsv2-server
Restart=always
RestartSec=15s
StandardOutput=journal
StandardError=journal
TimeoutStartSec=900

[Install]
WantedBy=multi-user.target
EOF
echo '[OK] unit installed'
