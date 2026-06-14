#!/usr/bin/env bash
set -euo pipefail

# Task: Local HTTP health check on 127.0.0.1:${STREAM_PORT}/stream/health
# Description (original):
#   uvicorn が listen するまで最大 30s 待ち、200 を返すかを確認する。

for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${STREAM_PORT}/stream/health" || echo 000)
  if [ "$code" = "200" ]; then echo "[OK] http=$code (attempt=$i)"; exit 0; fi
  sleep 1
done
echo '[NG] stream did not become healthy in 30s' >&2
systemctl status voice-image-edit-stream.service --no-pager || true
journalctl -u voice-image-edit-stream.service -n 50 --no-pager || true
exit 1
