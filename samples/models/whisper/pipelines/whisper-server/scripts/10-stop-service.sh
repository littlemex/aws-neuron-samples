#!/usr/bin/env bash
set -euo pipefail

# systemd unit があれば一旦止める。失敗しても続行。

systemctl stop whisper-server.service 2>/dev/null || true
echo '[OK] stop attempted'
