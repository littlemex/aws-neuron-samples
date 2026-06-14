#!/usr/bin/env bash
set -euo pipefail

# タスク説明: Next.js が listen するまで最大 30s 待ち、200 系を返すかを確認する。

for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${FRONTEND_PORT}/" || echo 000)
  case "$code" in
    2*|3*) echo "[OK] http=$code (attempt=$i)"; exit 0;;
  esac
  sleep 1
done
echo '[NG] frontend did not become healthy in 30s' >&2
systemctl status voice-image-edit-frontend.service --no-pager || true
journalctl -u voice-image-edit-frontend.service -n 50 --no-pager || true
exit 1
