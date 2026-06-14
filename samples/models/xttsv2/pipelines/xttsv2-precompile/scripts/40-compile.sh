#!/usr/bin/env bash
set -euo pipefail

# Task: Run compile_xttsv2_nxd.py inside the DLC (BF16)
# Description: Compile both Prefill + Decode applications inside the SDK 2.28 DLC.
# On trn2 with the bundled neuronx-cc 2.23 this finishes in ~1-2 minutes per stage.
# MALLOC_ARENA_MAX=2 reduces glibc fragmentation; --shm-size 8g satisfies torch_xla's
# shared-memory needs.

if [ -f "${COMPILED_MODEL_PATH}/.precompile_skipped" ] && [ "${FORCE_RECOMPILE}" != 'true' ]; then
  echo '[OK] skipped (cached)'
  exit 0
fi

mkdir -p "${COMPILED_MODEL_PATH}"

docker run --rm \
  --device /dev/neuron0 \
  --shm-size 8g \
  -e NEURON_RT_VISIBLE_CORES="${NEURON_CORES}" \
  -e NEURON_RT_NUM_CORES="${TP_DEGREE}" \
  -e NEURON_RT_VIRTUAL_CORE_SIZE=2 \
  -e NEURON_LOGICAL_NC_CONFIG=2 \
  -e MALLOC_ARENA_MAX=2 \
  -v /models:/models \
  -v "${WORK_DIR}/source":/src:ro \
  -w /src \
  --entrypoint /bin/bash \
  "${DLC_IMAGE}" \
  -lc "pip install --quiet 'coqui-tts==0.26.*' 'soundfile>=0.12' 2>&1 | tail -5 && pip install --quiet 'torchaudio==2.9.*' --extra-index-url https://download.pytorch.org/whl/cpu 2>&1 | tail -5 && python compile_xttsv2_nxd.py --model-path ${XTTS_MODEL_DIR} --output-dir ${COMPILED_MODEL_PATH} --tp-degree ${TP_DEGREE} --seq-len ${SEQ_LEN}"

echo '[OK] compiled'
