#!/usr/bin/env bash
set -euo pipefail

# タスク説明 (原文):
# 古い whisper-server.service / whisper-server-nxd.service が動いていれば
# 一旦止める。失敗しても続行。

systemctl stop whisper-server.service 2>/dev/null || true
systemctl stop whisper-server-nxd.service 2>/dev/null || true
echo "[OK] stop attempted"
