#!/usr/bin/env bash
set -euo pipefail

# compile_metadata.json + encoder/ + decoder/ が揃っていて FORCE_RECOMPILE=false なら exit 0。

if [ "${FORCE_RECOMPILE}" = 'true' ]; then
  echo '[INFO] FORCE_RECOMPILE=true, will recompile'
  exit 0
fi

if [ -f "${MODEL_DIR}/compile_metadata.json" ] && [ -d "${MODEL_DIR}/encoder" ] && [ -d "${MODEL_DIR}/decoder" ]; then
  echo '[OK] artifacts already present, skip'
  touch "${MODEL_DIR}/.precompile_skipped"
  exit 0
fi

echo '[INFO] artifacts missing, will compile'
