#!/usr/bin/env bash
set -euo pipefail

# compile_metadata.json + encoder/decoder/proj の 3 .pt が揃っていて
# FORCE_RECOMPILE=false なら exit 0。

if [ "${FORCE_RECOMPILE}" = 'true' ]; then
  echo '[INFO] FORCE_RECOMPILE=true, will recompile'
  exit 0
fi

if [ ! -f "${MODEL_DIR}/compile_metadata.json" ]; then
  echo '[INFO] no compile_metadata.json, will compile'
  exit 0
fi

suffix=$(python3 -c 'import json,sys; print(json.load(open("'"${MODEL_DIR}/compile_metadata.json"'"))["suffix"])')

all_present=1
for f in \
  "whisper_${suffix}_${BATCH_SIZE}_neuron_encoder.pt" \
  "whisper_${suffix}_${BATCH_SIZE}_${MAX_DEC_LEN}_neuron_decoder.pt" \
  "whisper_${suffix}_${BATCH_SIZE}_${MAX_DEC_LEN}_neuron_proj.pt"
do
  if [ ! -f "${MODEL_DIR}/$f" ]; then
    all_present=0
    echo "[INFO] missing $f"
  fi
done

if [ "$all_present" -eq 1 ]; then
  echo '[OK] artifacts already present, skip compile'
  touch "${MODEL_DIR}/.precompile_skipped"
  exit 0
fi

echo '[INFO] some artifacts missing, will compile'
