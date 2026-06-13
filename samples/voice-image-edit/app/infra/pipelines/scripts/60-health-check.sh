#!/usr/bin/env bash
# Hit the local /api/edit/health endpoint and confirm we get HTTP 200.
# Retries are configured at the YAML level (retries: 5, retry_delay: 5s)
# so we use a small inline loop here only as the last-mile guard - if all
# 5 retries fail, dump the unit status and recent journal to make
# diagnosis fast.
set -euo pipefail

url="http://127.0.0.1:${API_PORT}/api/edit/health"

for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || echo 000)
  if [[ "$code" == "200" ]]; then
    echo "[OK] http=$code (attempt=$i)"
    exit 0
  fi
  sleep 1
done

echo "[NG] api did not become healthy in 30s" >&2
systemctl status voice-image-edit-api.service --no-pager || true
journalctl -u voice-image-edit-api.service -n 50 --no-pager || true
exit 1
