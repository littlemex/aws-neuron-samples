#!/usr/bin/env bash
set -euo pipefail

# タスク説明 (原文):
# presigned URL から whisper_server_nxd.py を含む tarball を取得して
# SERVE_DIR に展開。

test -n "${SERVER_TARBALL_URL}" || { echo "[NG] SERVER_TARBALL_URL is empty"; exit 1; }
mkdir -p "$(dirname "${SERVE_DIR}")"
rm -rf "${SERVE_DIR}"
mkdir -p "${SERVE_DIR}"
tmp=$(mktemp /tmp/whisper-nxd-server.XXXXXX.tar.gz)
trap 'rm -f $tmp' EXIT
curl -fsSL "${SERVER_TARBALL_URL}" -o "$tmp"
tar -C "${SERVE_DIR}" -xzf "$tmp"
test -f "${SERVE_DIR}/whisper_server_nxd.py" || { echo "[NG] whisper_server_nxd.py missing after extract"; exit 1; }
chown -R "${SERVE_USER}:${SERVE_USER}" "${SERVE_DIR}"
echo "[OK] deployed"
