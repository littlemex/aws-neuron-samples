#!/usr/bin/env bash
set -euo pipefail

# Poll /health until HTTP 200 or timeout.
# After a compile-cache hit, the first start typically takes 600 s.
# After a cache miss (e.g. NVMe wiped on instance replacement) cold recompile
# can take up to 60 min, so we wait up to 3600 s (360 * 10 s).

for i in $(seq 1 360); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health" || echo 000)
  if [ "$code" = "200" ]; then echo "[OK] http=$code (attempt=$i)"; exit 0; fi
  sleep 10
done
echo '[NG] qwen3-vl did not become healthy in 3600s' >&2
systemctl status qwen3-vl.service --no-pager || true
journalctl -u qwen3-vl.service -n 200 --no-pager || true
exit 1
