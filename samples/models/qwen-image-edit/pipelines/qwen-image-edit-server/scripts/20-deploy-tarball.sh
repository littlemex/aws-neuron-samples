#!/usr/bin/env bash
set -euo pipefail

# Task: 20-deploy-tarball
# Description: presigned URL から tarball を SERVE_DIR に展開。

test -n "${SOURCE_TARBALL_URL}" || { echo "[NG] SOURCE_TARBALL_URL is empty"; exit 1; }

mkdir -p "$(dirname "${SERVE_DIR}")"
rm -rf "${SERVE_DIR}"
mkdir -p "${SERVE_DIR}"

tmp=$(mktemp /tmp/qwen-image-edit-server.XXXXXX.tar.gz)
trap 'rm -f "$tmp"' EXIT

curl -fsSL "${SOURCE_TARBALL_URL}" -o "$tmp"
tar -C "${SERVE_DIR}" -xzf "$tmp"

test -f "${SERVE_DIR}/serve.py"  || { echo "[NG] serve.py missing";  exit 1; }
test -f "${SERVE_DIR}/start.sh"  || { echo "[NG] start.sh missing";  exit 1; }

chmod +x "${SERVE_DIR}/start.sh"
chown -R "${SERVE_USER}:${SERVE_USER}" "${SERVE_DIR}"

echo "[OK] deployed"
