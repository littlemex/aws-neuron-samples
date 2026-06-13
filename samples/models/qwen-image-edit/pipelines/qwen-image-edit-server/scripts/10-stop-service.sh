#!/usr/bin/env bash
set -euo pipefail

# Task: 10-stop-service
# Description: systemd unit があれば一旦止める。

systemctl stop qwen-image-edit.service 2>/dev/null || true
echo "[OK] stop attempted"
