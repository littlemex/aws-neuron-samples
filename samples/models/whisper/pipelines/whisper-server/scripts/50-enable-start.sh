#!/usr/bin/env bash
set -euo pipefail

# systemd を再読込してサービスを有効化・起動する。

systemctl daemon-reload
systemctl enable whisper-server.service
systemctl restart whisper-server.service
echo '[OK] service started'
