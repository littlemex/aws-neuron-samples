#!/usr/bin/env bash
set -euo pipefail

# Neuron venv 内で compile_whisper.py を実行。NeuronCore 8 を専有。BF16 auto-cast。
# batch_size / max_dec_len は variable で渡す。output 先は MODEL_DIR。
# 重い処理 (~30 min)、SSM Run Command の execution timeout に注意 (デフォルトで 1h)。

if [ -f "${MODEL_DIR}/.precompile_skipped" ] && [ "${FORCE_RECOMPILE}" != 'true' ]; then
  echo '[OK] skipped (cached)'
  exit 0
fi

mkdir -p "${MODEL_DIR}"

export NEURON_RT_VISIBLE_CORES="${NEURON_CORE}"
export NEURON_RT_NUM_CORES=1

cd "${WORK_DIR}"
# shellcheck disable=SC1091
. "${VENV}/bin/activate"

"${VENV}/bin/pip" install --quiet 'datasets<3' 'librosa>=0.10' 'soundfile>=0.12' 2>&1 | tail -5 || true

python compile_whisper.py \
  --model-id "${MODEL_ID}" \
  --output-dir "${MODEL_DIR}" \
  --batch-size "${BATCH_SIZE}" \
  --max-dec-len "${MAX_DEC_LEN}" \
  --skip-validation

echo '[OK] compiled'
