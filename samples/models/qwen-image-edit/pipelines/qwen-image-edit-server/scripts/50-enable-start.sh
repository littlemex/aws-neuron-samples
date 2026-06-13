#!/usr/bin/env bash
set -euo pipefail

# Task: 50-enable-start
# Description: systemd を再読込してサービスを有効化・起動する。

systemctl daemon-reload
systemctl enable qwen-image-edit.service
systemctl restart qwen-image-edit.service
echo "[OK] service started"
