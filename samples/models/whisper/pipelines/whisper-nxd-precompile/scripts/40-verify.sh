#!/usr/bin/env bash
set -euo pipefail

# compile_metadata.json + encoder/ + decoder/ が揃っていることを確認する。

test -f "${MODEL_DIR}/compile_metadata.json" || { echo '[NG] compile_metadata.json missing'; exit 1; }
test -d "${MODEL_DIR}/encoder" || { echo '[NG] encoder/ missing'; exit 1; }
test -d "${MODEL_DIR}/decoder" || { echo '[NG] decoder/ missing'; exit 1; }
du -sh "${MODEL_DIR}/encoder" "${MODEL_DIR}/decoder"
cat "${MODEL_DIR}/compile_metadata.json"
echo '[OK] artifacts verified'
