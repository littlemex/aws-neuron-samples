#!/usr/bin/env bash
set -euo pipefail

# Task: Download + extract xttsv2 server tarball into SERVE_DIR
# Fetch source via presigned URL and extract under SERVE_DIR.
# The tarball carries xttsv2_server.py + neuron_xttsv2/ + Dockerfile.server
# (which is built locally next).

test -n "${SOURCE_TARBALL_URL}" || { echo '[NG] SOURCE_TARBALL_URL is empty'; exit 1; }
mkdir -p "$(dirname "${SERVE_DIR}")"
rm -rf "${SERVE_DIR}"
mkdir -p "${SERVE_DIR}"
tmp=$(mktemp /tmp/xttsv2-server.XXXXXX.tar.gz)
trap 'rm -f $tmp' EXIT
curl -fsSL "${SOURCE_TARBALL_URL}" -o "$tmp"
tar -C "${SERVE_DIR}" -xzf "$tmp"
test -f "${SERVE_DIR}/xttsv2_server.py" || { echo '[NG] xttsv2_server.py missing after extract'; exit 1; }
test -d "${SERVE_DIR}/neuron_xttsv2" || { echo '[NG] neuron_xttsv2/ missing after extract'; exit 1; }
test -f "${SERVE_DIR}/Dockerfile.server" || { echo '[NG] Dockerfile.server missing after extract'; exit 1; }
chown -R "${SERVE_USER}:${SERVE_USER}" "${SERVE_DIR}"
echo '[OK] deployed'
