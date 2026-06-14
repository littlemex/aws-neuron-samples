#!/usr/bin/env bash
set -euo pipefail

# タスク説明 (原文):
# systemd を再読込してサービスを有効化・起動する。

systemctl daemon-reload
systemctl enable whisper-server-nxd.service
systemctl restart whisper-server-nxd.service
echo "[OK] service started"
