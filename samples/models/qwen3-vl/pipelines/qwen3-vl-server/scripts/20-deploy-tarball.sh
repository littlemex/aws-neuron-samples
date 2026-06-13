#!/usr/bin/env bash
set -euo pipefail

# Task: Download + extract qwen3-vl server tarball (start.sh)
# Description: presigned URL から start.sh を含む tarball を取得して SERVE_DIR に展開。

test -n "${SERVER_TARBALL_URL}" || { echo '[NG] SERVER_TARBALL_URL is empty'; exit 1; }
mkdir -p "$(dirname "${SERVE_DIR}")"
rm -rf "${SERVE_DIR}"
mkdir -p "${SERVE_DIR}"
tmp=$(mktemp /tmp/qwen3-vl-server.XXXXXX.tar.gz)
trap 'rm -f $tmp' EXIT
curl -fsSL "${SERVER_TARBALL_URL}" -o "$tmp"
tar -C "${SERVE_DIR}" -xzf "$tmp"
test -f "${SERVE_DIR}/start.sh" || { echo '[NG] start.sh missing after extract'; exit 1; }
chmod +x "${SERVE_DIR}/start.sh"
chown -R "${SERVE_USER}:${SERVE_USER}" "${SERVE_DIR}"
echo '[OK] deployed'
