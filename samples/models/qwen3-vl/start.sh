#!/usr/bin/env bash
# Qwen3-VL-8B-Thinking 個別起動 (vLLM + Neuron, TP=16, NeuronCore 0-15)
# 既に同ポートで起動中の場合はスキップ。
set -euo pipefail

PORT="${PORT:-8090}"
MODEL_DIR="${MODEL_DIR:-/models/Qwen3-VL-8B-Thinking}"
VENV="${VENV:-/opt/aws_neuronx_venv_pytorch_inference_vllm_0_16}"
NEURON_CORES="${NEURON_CORES:-0-15}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --model-dir) MODEL_DIR="$2"; shift 2 ;;
    --venv) VENV="$2"; shift 2 ;;
    --cores) NEURON_CORES="$2"; shift 2 ;;
    *) echo "[qwen3] Unknown arg: $1"; exit 1 ;;
  esac
done

LOG_DIR="${LOG_DIR:-$(cd "$(dirname "$0")" && pwd)/logs}"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/qwen3.log"
PIDFILE="$LOG_DIR/qwen3.pid"

if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
  echo "[qwen3] port ${PORT} already listening — skip start"
  exit 0
fi

if [[ ! -f "${MODEL_DIR}/config.json" ]]; then
  echo "[qwen3] ERROR: model not found at ${MODEL_DIR}"
  exit 1
fi

# shellcheck disable=SC1091
source "${VENV}/bin/activate"

export NEURON_RT_VISIBLE_CORES="${NEURON_CORES}"
export VLLM_NEURON_FRAMEWORK=neuronx-distributed-inference
export NEURON_RT_DBG_INTRA_RDH_CHANNEL_BUFFER_SIZE=146800640

ADDITIONAL_CONFIG=$(python3 -c "
import json
print(json.dumps({'override_neuron_config': {
  'text_neuron_config': {
    'batch_size':1,'ctx_batch_size':1,'tkg_batch_size':1,
    'seq_len':32768,'max_context_length':32768,
    'enable_bucketing':True,
    'context_encoding_buckets':[2048,5120,32768],
    'token_generation_buckets':[2048,5120,32768],
    'world_size':16,'tp_degree':16,
    'torch_dtype':'bfloat16','rpl_reduce_dtype':'bfloat16','attention_dtype':'bfloat16',
    'cast_type':'as-declared','logical_neuron_cores':2,'cc_pipeline_tiling_factor':2,
    'fused_qkv':True,'qkv_kernel_enabled':True,'mlp_kernel_enabled':True,'attn_kernel_enabled':True
  },
  'vision_neuron_config': {
    'batch_size':1,'seq_len':16384,'max_context_length':16384,
    'enable_bucketing':True,'buckets':[1024,16384],
    'world_size':16,'tp_degree':16,
    'torch_dtype':'bfloat16','rpl_reduce_dtype':'bfloat16',
    'cast_type':'as-declared','logical_neuron_cores':2,'cc_pipeline_tiling_factor':2,
    'fused_qkv':True,'attn_kernel_enabled':False,'mlp_kernel_enabled':False
  }
}}))
")
LIMIT_MM='{"image":20}'

echo "[qwen3] launching vLLM on :${PORT} (TP=16, cores=${NEURON_CORES})"
nohup vllm serve \
  --model="${MODEL_DIR}" --tokenizer="${MODEL_DIR}" \
  --trust-remote-code --dtype=bfloat16 \
  --tensor-parallel-size=16 --max-num-seqs=1 --max-model-len=32768 \
  --additional-config="${ADDITIONAL_CONFIG}" \
  --limit-mm-per-prompt="${LIMIT_MM}" \
  --no-enable-chunked-prefill --no-enable-prefix-caching \
  --host=0.0.0.0 --port="${PORT}" \
  >>"${LOG}" 2>&1 &

echo $! > "${PIDFILE}"
echo "[qwen3] pid=$(cat "${PIDFILE}") log=${LOG}"
