#!/usr/bin/env bash
set -euo pipefail

# タスク説明: Restart=always で常駐。HOSTNAME=0.0.0.0 PORT=3000 で internal ALB から到達可能にする。
# NEXT_PUBLIC_EDIT_API_PATH は build-time 注入だが、Next.js の env.ts は process.env から実行時にも読むためここで指定。

cat > /etc/systemd/system/voice-image-edit-frontend.service <<EOF
[Unit]
Description=voice-image-edit Next.js frontend (standalone)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${FRONTEND_USER}
WorkingDirectory=${FRONTEND_DIR}
Environment=NODE_ENV=production
Environment=HOSTNAME=0.0.0.0
Environment=PORT=${FRONTEND_PORT}
Environment=NEXT_PUBLIC_EDIT_API_PATH=${EDIT_API_PATH}
ExecStart=/usr/bin/node ${FRONTEND_DIR}/server.js
Restart=always
RestartSec=5s
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
echo '[OK] unit installed'
