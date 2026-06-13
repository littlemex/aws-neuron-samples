#!/usr/bin/env bash
set -euo pipefail

# Task: Install voice-image-edit-stream.service systemd unit
# Description (original):
#   Restart=always で常駐。0.0.0.0:${STREAM_PORT} で listen し、ALB から到達可能にする。

cat > /etc/systemd/system/voice-image-edit-stream.service <<EOF
[Unit]
Description=voice-image-edit SSE backend (FastAPI/uvicorn)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${STREAM_USER}
WorkingDirectory=${STREAM_DIR}
Environment=PYTHONUNBUFFERED=1
Environment=LOG_LEVEL=INFO
Environment=EDIT_API_BASE_URL=${EDIT_API_BASE_URL}
Environment=ORIGIN_VERIFY_HEADER_NAME=${ORIGIN_VERIFY_HEADER_NAME}
Environment=ORIGIN_VERIFY_HEADER_VALUE=${ORIGIN_VERIFY_HEADER_VALUE}
ExecStart=${STREAM_DIR}/venv/bin/uvicorn app:app --host 0.0.0.0 --port ${STREAM_PORT} --proxy-headers --no-server-header --timeout-keep-alive 75
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
echo '[OK] unit installed'
