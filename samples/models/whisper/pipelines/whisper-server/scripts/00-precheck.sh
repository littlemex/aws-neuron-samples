#!/usr/bin/env bash
set -euo pipefail

# venv と compile_metadata.json が存在すること (= 先に precompile タスクが走っていること) を確認。

test -x "${VENV}/bin/python" || { echo '[NG] venv missing: '"${VENV}"; exit 1; }
test -f "${MODEL_DIR}/compile_metadata.json" || { echo '[NG] '"${MODEL_DIR}"'/compile_metadata.json missing — run whisper-precompile.json first'; exit 1; }
id "${SERVE_USER}" >/dev/null 2>&1 || { echo '[NG] user '"${SERVE_USER}"' missing'; exit 1; }
command -v ffmpeg >/dev/null || { echo '[INFO] ffmpeg missing, will be installed'; }
echo '[OK] precheck'
