#!/usr/bin/env bash
set -euo pipefail

# Task: 20-deploy-tarball
# Name: Download + extract neuron-anatomy backend tarball
# Description: Fetch the backend source via presigned S3 URL and extract under SERVE_DIR.

test -n "${SOURCE_TARBALL_URL}" || { echo '[NG] SOURCE_TARBALL_URL is empty'; exit 1; }
mkdir -p "$(dirname "${SERVE_DIR}")"
rm -rf "${SERVE_DIR}/backend"
mkdir -p "${SERVE_DIR}/backend"
tmp=$(mktemp /tmp/neuron-anatomy-backend.XXXXXX.tar.gz)
trap 'rm -f "$tmp"' EXIT
curl -fsSL "${SOURCE_TARBALL_URL}" -o "$tmp"
tar -C "${SERVE_DIR}/backend" -xzf "$tmp"
test -f "${SERVE_DIR}/backend/main.py" || { echo '[NG] main.py missing after extract'; exit 1; }
test -d "${SERVE_DIR}/backend/neuron_anatomy" || { echo '[NG] neuron_anatomy/ missing after extract'; exit 1; }
chown -R "${SERVE_USER}:${SERVE_USER}" "${SERVE_DIR}"
echo '[OK] deployed'
