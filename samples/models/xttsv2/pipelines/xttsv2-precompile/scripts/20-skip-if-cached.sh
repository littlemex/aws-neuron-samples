#!/usr/bin/env bash
set -euo pipefail

# Task: Skip the heavy compile if artefacts already exist
# Description: Bail out early when prefill/ + decode/ + .compile_metadata.json are all
# present and FORCE_RECOMPILE=false.

if [ "${FORCE_RECOMPILE}" = 'true' ]; then
  echo '[INFO] FORCE_RECOMPILE=true, will recompile'
  rm -f "${COMPILED_MODEL_PATH}/.precompile_skipped"
  exit 0
fi

if [ -f "${COMPILED_MODEL_PATH}/.compile_metadata.json" ] \
  && [ -d "${COMPILED_MODEL_PATH}/prefill" ] \
  && [ -d "${COMPILED_MODEL_PATH}/decode" ]; then
  echo '[OK] artefacts already present, skip'
  touch "${COMPILED_MODEL_PATH}/.precompile_skipped"
  exit 0
fi

echo '[INFO] artefacts missing, will compile'
