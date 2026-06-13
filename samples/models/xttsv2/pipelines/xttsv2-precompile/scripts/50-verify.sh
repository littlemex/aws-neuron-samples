#!/usr/bin/env bash
set -euo pipefail

# Task: Verify compiled artefacts
# Description: .compile_metadata.json + prefill/ + decode/ must all be present.

test -f "${COMPILED_MODEL_PATH}/.compile_metadata.json" \
  || { echo '[NG] .compile_metadata.json missing'; exit 1; }
test -d "${COMPILED_MODEL_PATH}/prefill" \
  || { echo '[NG] prefill/ missing'; exit 1; }
test -d "${COMPILED_MODEL_PATH}/decode" \
  || { echo '[NG] decode/ missing'; exit 1; }

du -sh "${COMPILED_MODEL_PATH}/prefill" "${COMPILED_MODEL_PATH}/decode"
cat "${COMPILED_MODEL_PATH}/.compile_metadata.json"
echo '[OK] artefacts verified'
