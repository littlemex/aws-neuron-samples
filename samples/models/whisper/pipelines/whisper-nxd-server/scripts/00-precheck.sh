#!/usr/bin/env bash
set -euo pipefail

# タスク説明 (原文):
# venv と compile_metadata.json + encoder/ + decoder/ が存在すること
# (= 先に precompile タスクが走っていること) を確認。

test -x "${VENV}/bin/python" || { echo "[NG] venv missing: ${VENV}"; exit 1; }
test -f "${MODEL_DIR}/compile_metadata.json" || { echo "[NG] ${MODEL_DIR}/compile_metadata.json missing — run whisper-nxd-precompile.json first"; exit 1; }
test -d "${MODEL_DIR}/encoder" || { echo "[NG] ${MODEL_DIR}/encoder/ missing"; exit 1; }
test -d "${MODEL_DIR}/decoder" || { echo "[NG] ${MODEL_DIR}/decoder/ missing"; exit 1; }
id "${SERVE_USER}" >/dev/null 2>&1 || { echo "[NG] user ${SERVE_USER} missing"; exit 1; }
echo "[OK] precheck"
