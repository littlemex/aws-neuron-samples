#!/usr/bin/env bash
set -euo pipefail

# NxD Inference で encoder + decoder を一括コンパイル。
# NEURON_RT_VISIBLE_CORES=${NEURON_CORES} で 8 core 専有。
# 重い処理 (~30-60 min)、SSM Run Command の execution timeout に注意。

if [ -f "${MODEL_DIR}/.precompile_skipped" ] && [ "${FORCE_RECOMPILE}" != 'true' ]; then
  echo '[OK] skipped (cached)'
  exit 0
fi

mkdir -p "${MODEL_DIR}"
export PATH="${VENV}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export NEURON_RT_VISIBLE_CORES="${NEURON_CORES}"
export HF_HOME="${HF_HOME}"
mkdir -p "${HF_HOME}"
cd "${WORK_DIR}"

FORCE_FLAG=''
if [ "${FORCE_RECOMPILE}" = 'true' ]; then
  FORCE_FLAG='--force'
fi

"${VENV}/bin/python" compile_whisper_nxd.py \
  --model-id "${MODEL_ID}" \
  --output-dir "${MODEL_DIR}" \
  --tp-degree "${TP_DEGREE}" \
  --batch-size "${BATCH_SIZE}" \
  --dtype "${DTYPE}" \
  ${FORCE_FLAG:+$FORCE_FLAG}

echo '[OK] compiled'
