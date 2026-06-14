#!/usr/bin/env bash
set -euo pipefail

# warmup を含むため起動に時間がかかる。最大 300s 待つ。
# 200 を返したら OK。
# retries/retry_delay は YAML 側で管理するため、ここでは 1 回だけ試みる。

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health" || echo 000)
if [ "${code}" = "200" ]; then
  echo "[OK] http=${code}"
  curl -s "http://127.0.0.1:${PORT}/health"
  echo
  exit 0
fi
echo "[NG] whisper-server not healthy yet: http=${code}" >&2
systemctl status whisper-server.service --no-pager || true
journalctl -u whisper-server.service -n 100 --no-pager || true
exit 1
