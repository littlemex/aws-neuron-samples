#!/usr/bin/env bash
set -euo pipefail

# Task: Stop existing qwen3-vl.service (if any)
# Description: systemd unit があれば一旦止める。失敗しても続行。

systemctl stop qwen3-vl.service 2>/dev/null || true
echo '[OK] stop attempted'
