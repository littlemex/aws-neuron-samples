#!/usr/bin/env bash
set -euo pipefail

# compile_metadata.json + 3 .pt が揃っていることを確認する。

test -f "${MODEL_DIR}/compile_metadata.json" || { echo '[NG] compile_metadata.json missing'; exit 1; }

suffix=$(python3 -c 'import json; print(json.load(open("'"${MODEL_DIR}/compile_metadata.json"'"))["suffix"])')

for f in \
  "whisper_${suffix}_${BATCH_SIZE}_neuron_encoder.pt" \
  "whisper_${suffix}_${BATCH_SIZE}_${MAX_DEC_LEN}_neuron_decoder.pt" \
  "whisper_${suffix}_${BATCH_SIZE}_${MAX_DEC_LEN}_neuron_proj.pt"
do
  test -f "${MODEL_DIR}/$f" || { echo "[NG] missing $f"; exit 1; }
  ls -lh "${MODEL_DIR}/$f"
done

echo '[OK] artifacts verified'
