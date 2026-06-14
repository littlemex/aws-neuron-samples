#!/usr/bin/env bash
set -euo pipefail

# Task: Download + extract stream backend tarball (preserves venv/)
# Description (original):
#   presigned URL で tarball を取得し ${STREAM_DIR} に展開する。venv/ は 30-create-venv が管理するので
#   破壊しない。tar 展開後に ${STREAM_USER} 所有権を必ず張り直し、後続 30 が ubuntu として書けるようにする。

test -n "${STREAM_TARBALL_URL}" || { echo '[NG] STREAM_TARBALL_URL is empty'; exit 1; }
mkdir -p "${STREAM_DIR}"
find "${STREAM_DIR}" -mindepth 1 -maxdepth 1 -not -name venv -exec rm -rf {} +
tmp=$(mktemp /tmp/voice-image-edit-stream.XXXXXX.tar.gz)
trap 'rm -f $tmp' EXIT
curl -fsSL "${STREAM_TARBALL_URL}" -o "$tmp"
tar -C "${STREAM_DIR}" -xzf "$tmp"
test -f "${STREAM_DIR}/app.py" || { echo '[NG] app.py missing after extract'; exit 1; }
test -f "${STREAM_DIR}/requirements.txt" || { echo '[NG] requirements.txt missing'; exit 1; }
find "${STREAM_DIR}" -mindepth 1 -maxdepth 1 -not -name venv -exec chown -R "${STREAM_USER}:${STREAM_USER}" {} +
chown "${STREAM_USER}:${STREAM_USER}" "${STREAM_DIR}"
echo '[OK] deployed (venv preserved)'
