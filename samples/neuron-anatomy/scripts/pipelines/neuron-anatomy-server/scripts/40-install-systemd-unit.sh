#!/usr/bin/env bash
set -euo pipefail

# Task: 40-install-systemd-unit
# Name: Install neuron-anatomy.service systemd unit
# Description: Listens on 127.0.0.1:${ANATOMY_PORT} (the ALB target group reaches it
#              via the EC2 security group ingress installed by NeuronAnatomyStack).
#              Restart=always so the daemon survives a transient neuron-monitor failure.

cat > /etc/systemd/system/neuron-anatomy.service <<EOF
[Unit]
Description=neuron-anatomy live dashboard backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${SERVE_USER}
Group=${SERVE_USER}
WorkingDirectory=${SERVE_DIR}/backend
Environment=PYTHONUNBUFFERED=1
Environment=LOG_LEVEL=INFO
Environment=NEURON_MONITOR_BIN=${NEURON_MONITOR_BIN}
Environment=NEURON_LS_BIN=${NEURON_LS_BIN}
Environment=NEURON_MONITOR_PERIOD_S=${NEURON_MONITOR_PERIOD_S}
ExecStart=${VENV}/bin/uvicorn main:app --host 0.0.0.0 --port ${ANATOMY_PORT} --workers 1 --no-server-header --timeout-keep-alive 75
Restart=always
RestartSec=3
NoNewPrivileges=true
ProtectSystem=full
ProtectHome=read-only
PrivateTmp=true

[Install]
WantedBy=multi-user.target
EOF
echo '[OK] unit installed'
