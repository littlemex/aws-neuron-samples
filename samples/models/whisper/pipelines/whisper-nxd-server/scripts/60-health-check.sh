#!/usr/bin/env bash
set -euo pipefail

# タスク説明 (原文):
# warmup を含むため起動に時間がかかる。最大 600s 待つ。
# 200 を返したら OK。

for i in $(seq 1 120); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health" || echo 000)
  if [ "$code" = "200" ]; then
    echo "[OK] http=$code (attempt=$i)"
    curl -s "http://127.0.0.1:${PORT}/health"
    echo
    exit 0
  fi
  sleep 5
done
echo "[NG] whisper-server-nxd did not become healthy in 600s" >&2
systemctl status whisper-server-nxd.service --no-pager || true
journalctl -u whisper-server-nxd.service -n 200 --no-pager || true
exit 1
