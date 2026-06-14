#!/usr/bin/env bash
set -euo pipefail

# Task: Local HTTP health check on 127.0.0.1:${PORT}/health
# Warm-up loads model weights into NeuronCores; allow up to 600s.
# The retry loop (120 attempts x 5s = 600s) is expressed as retries/retry_delay
# in the YAML; this script performs a single attempt and exits 0 on 200.

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health" || echo 000)
if [ "${code}" = "200" ]; then
  echo "[OK] http=${code}"
  curl -s "http://127.0.0.1:${PORT}/health"
  echo
  exit 0
fi

echo "[NG] xttsv2-server not healthy yet (http=${code})" >&2
systemctl status xttsv2-server.service --no-pager || true
journalctl -u xttsv2-server.service -n 200 --no-pager || true
docker logs xttsv2-server --tail 200 2>&1 || true
exit 1
