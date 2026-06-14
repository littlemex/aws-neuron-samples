#!/usr/bin/env bash
set -euo pipefail

# Task: Run compile.sh v3_tp16 (~90-120 min, NeuronCore ${NEURON_CORES}, world_size=32)
# Description: compile.sh v3_tp16 は VAE + Transformer (V3 TP16) + Language Model + Vision Encoder の 4 コンポーネントを順に compile する。
#   NeuronCore は 32-63 (32 cores, world_size=32, TP=16, DP=2)。
#   24 attention heads は 32 にパディングされ 16 rank に分割 (2 heads/rank、25% padding overhead)。
#   edit ステージのレイテンシ削減を最優先。

if [ -f "${COMPILED_MODELS_DIR}/.precompile_skipped" ] && [ "${FORCE_RECOMPILE}" != 'true' ]; then
  echo '[OK] skipped (cached)'
  exit 0
fi

mkdir -p "${COMPILED_MODELS_DIR}" "${COMPILER_WORKDIR}" "${HF_CACHE_DIR}"
cd "${WORK_DIR}"

. "${VENV}/bin/activate"

export PYTHONPATH="${WORK_DIR}:${PYTHONPATH:-}"
export NEURON_RT_VISIBLE_CORES="${NEURON_CORES}"
export NEURON_RT_NUM_CORES="${WORLD_SIZE}"
export NEURON_RT_VIRTUAL_CORE_SIZE=2
export NEURON_LOGICAL_NC_CONFIG=2
export HUGGINGFACE_CACHE_DIR="${HF_CACHE_DIR}"
export HF_HOME="${HF_CACHE_DIR}"

ln -sfn "${HF_CACHE_DIR}" /mnt/local/qwen_image_edit_hf_cache_dir

echo '[INFO] starting compile.sh v3_tp16 (this populates Neuron compile cache, ~90-120 min)'
bash compile.sh v3_tp16 "${HEIGHT}" "${WIDTH}" "${IMAGE_SIZE}" 8 "${MAX_SEQ_LEN}" "${PATCH_MULTIPLIER}" 1
echo '[OK] compile.sh v3_tp16 finished'

# chown only if SERVE_USER exists on this host; server may need manual ownership fix otherwise
id "${SERVE_USER}" >/dev/null 2>&1 && {
  chown -R "${SERVE_USER}:${SERVE_USER}" "${COMPILED_MODELS_DIR}"
  chmod -R u+rwX,go+rX "${COMPILED_MODELS_DIR}"
} || echo "[WARN] ${SERVE_USER} missing on this host; skipping chown (server will need manual ownership fix)"
