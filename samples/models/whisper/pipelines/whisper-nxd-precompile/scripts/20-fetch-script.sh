#!/usr/bin/env bash
set -euo pipefail

# presigned S3 URL から compile_whisper_nxd.py を WORK_DIR に取得する。

if [ -f "${MODEL_DIR}/.precompile_skipped" ] && [ "${FORCE_RECOMPILE}" != 'true' ]; then
  echo '[OK] skipped (cached)'
  exit 0
fi

test -n "${COMPILE_SCRIPT_URL}" || { echo '[NG] COMPILE_SCRIPT_URL is empty'; exit 1; }
mkdir -p "${WORK_DIR}"
curl -fsSL "${COMPILE_SCRIPT_URL}" -o "${WORK_DIR}/compile_whisper_nxd.py"
test -s "${WORK_DIR}/compile_whisper_nxd.py" || { echo '[NG] compile_whisper_nxd.py is empty'; exit 1; }
head -1 "${WORK_DIR}/compile_whisper_nxd.py"
echo '[OK] script fetched'
