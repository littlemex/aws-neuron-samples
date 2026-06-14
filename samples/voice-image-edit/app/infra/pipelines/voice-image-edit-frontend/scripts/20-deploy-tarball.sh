#!/usr/bin/env bash
set -euo pipefail

# タスク説明: presigned URL で tarball を取得し FRONTEND_DIR に展開する。
# Frontend は venv を持たず Next.js standalone (server.js + node_modules + .next/) なので、
# tarball の中身全体を毎回入れ替える形で OK。展開後に server.js の存在を必ず検証して
# 40-enable-start が ExecStart で 203/EXEC を踏まないよう保証する。

test -n "${FRONTEND_TARBALL_URL}" || { echo '[NG] FRONTEND_TARBALL_URL is empty'; exit 1; }
mkdir -p "${FRONTEND_DIR}"
find "${FRONTEND_DIR}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
tmp=$(mktemp /tmp/voice-image-edit-frontend.XXXXXX.tar.gz)
trap 'rm -f "$tmp"' EXIT
curl -fsSL "${FRONTEND_TARBALL_URL}" -o "$tmp"
tar -C "${FRONTEND_DIR}" -xzf "$tmp"
test -f "${FRONTEND_DIR}/server.js" || { echo '[NG] server.js missing after extract'; exit 1; }
chown -R "${FRONTEND_USER}:${FRONTEND_USER}" "${FRONTEND_DIR}"
test -r "${FRONTEND_DIR}/server.js" || { echo '[NG] server.js not readable by root after chown'; exit 1; }
echo '[OK] deployed'
