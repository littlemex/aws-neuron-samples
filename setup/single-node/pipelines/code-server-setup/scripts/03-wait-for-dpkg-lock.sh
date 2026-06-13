#!/usr/bin/env bash
set -euo pipefail

# Task: Wait for dpkg lock
# Wait for any concurrent apt/dpkg processes to release their lock before installing packages

echo '==> Waiting for dpkg lock to be released'
timeout=300
elapsed=0
while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || fuser /var/lib/apt/lists/lock >/dev/null 2>&1 || fuser /var/cache/apt/archives/lock >/dev/null 2>&1; do
  if [ $elapsed -ge $timeout ]; then
    echo 'Timeout waiting for dpkg lock'
    break
  fi
  echo "Waiting for dpkg lock... ($elapsed seconds)"
  sleep 5
  elapsed=$((elapsed + 5))
done
echo 'dpkg lock released'
