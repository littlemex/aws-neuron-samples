#!/usr/bin/env bash
set -euo pipefail

# Task: Smoke check the service through nginx
# Description: Confirm /explorer/ returns the SPA shell and
#   /explorer/api/v1/profiles/search responds.

echo '==> Smoke check'

# Retry logic is handled by the runner (retries: 15, retry_delay: 2s).
# This single attempt is what gets retried.
if curl -sf "http://127.0.0.1${NGINX_LOCATION}/" >/dev/null; then
  echo 'UI shell reachable'
else
  echo 'UI shell not yet reachable'
  exit 1
fi

echo "--- ${NGINX_LOCATION}/ headers ---"
curl -sI "http://127.0.0.1${NGINX_LOCATION}/" | head -5

echo "--- ${NGINX_LOCATION}/api/v1/profiles/search status ---"
curl -s -o /dev/null -w 'HTTP %{http_code}\n' "http://127.0.0.1${NGINX_LOCATION}/api/v1/profiles/search"

echo '--- service status ---'
systemctl is-active neuron-explorer || true

echo '--- log tail ---'
tail -10 "${EXPLORER_DATA_DIR}/logs/explorer.log" 2>/dev/null || true
