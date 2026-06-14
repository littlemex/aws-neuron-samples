#!/usr/bin/env bash
set -euo pipefail

# Task: Local HTTP health check on 127.0.0.1:${PORT}/health
# Description: warmup cache 適用後でも初回 launch は 600s 程度かかる。 最大 1500s 待つ。

for i in $(seq 1 150); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health" || echo 000)
  if [ "$code" = "200" ]; then echo "[OK] http=$code (attempt=$i)"; exit 0; fi
  sleep 10
done
echo '[NG] qwen3-vl did not become healthy in 1500s' >&2
systemctl status qwen3-vl.service --no-pager || true
journalctl -u qwen3-vl.service -n 200 --no-pager || true
exit 1
