#!/usr/bin/env bash
set -euo pipefail

# presigned S3 URL から compile_whisper.py を WORK_DIR に取得する。
# FORCE_RECOMPILE=false かつ skip マーカーがある場合は SKIP。

if [ -f "${MODEL_DIR}/.precompile_skipped" ] && [ "${FORCE_RECOMPILE}" != 'true' ]; then
  echo '[OK] skipped (cached)'
  exit 0
fi

test -n "${COMPILE_SCRIPT_URL}" || { echo '[NG] COMPILE_SCRIPT_URL is empty'; exit 1; }

mkdir -p "${WORK_DIR}"
curl -fsSL "${COMPILE_SCRIPT_URL}" -o "${WORK_DIR}/compile_whisper.py"
test -s "${WORK_DIR}/compile_whisper.py" || { echo '[NG] compile_whisper.py is empty'; exit 1; }
head -1 "${WORK_DIR}/compile_whisper.py"
echo '[OK] script fetched'
