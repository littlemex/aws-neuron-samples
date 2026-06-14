#!/usr/bin/env bash
set -euo pipefail

# Task: daemon-reload + enable + start qwen3-vl
# Description: systemd を再読込してサービスを有効化・起動する。

systemctl daemon-reload
systemctl enable qwen3-vl.service
systemctl restart qwen3-vl.service
echo '[OK] service started'
