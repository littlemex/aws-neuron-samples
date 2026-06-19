#!/usr/bin/env bash
set -euo pipefail

# Launch vllm serve in one-shot warm-up mode (TP=16, NeuronCores ${NEURON_CORES}).
# Kill it after /health returns 200 (within 7200 s). Neuron compile artifacts
# are written to NEURON_COMPILE_CACHE_URL (EFS-backed) so they survive instance
# replacement. Once the cache is populated, subsequent vllm serve starts in
# minutes rather than ~60 min.

if [ -f "${MODEL_DIR}/.precompile_skipped" ] && [ "${FORCE_REWARMUP}" != "true" ]; then
  echo "[OK] skipped (cached)"
  exit 0
fi

. "${VENV}/bin/activate"

export NEURON_RT_VISIBLE_CORES="${NEURON_CORES}"
export VLLM_NEURON_FRAMEWORK=neuronx-distributed-inference
export NEURON_RT_DBG_INTRA_RDH_CHANNEL_BUFFER_SIZE=146800640
mkdir -p "${COMPILE_CACHE}"
export NEURON_COMPILE_CACHE_URL="${COMPILE_CACHE}"
echo "[INFO] NEURON_COMPILE_CACHE_URL=${COMPILE_CACHE} (EFS-backed; survives instance replacement)"

_lo=$(echo "${NEURON_CORES}" | cut -d- -f1)
_hi=$(echo "${NEURON_CORES}" | cut -d- -f2)
TP=$((_hi - _lo + 1))
echo "[INFO] derived TP=${TP} from NEURON_CORES=${NEURON_CORES}"

ADDITIONAL_CONFIG=$(TP=${TP} python3 -c "
import json, os
tp = int(os.environ['TP'])
print(json.dumps({
  'override_neuron_config': {
    'text_neuron_config': {
      'batch_size': 1,
      'ctx_batch_size': 1,
      'tkg_batch_size': 1,
      'seq_len': 32768,
      'max_context_length': 32768,
      'enable_bucketing': True,
      'context_encoding_buckets': [2048, 5120, 32768],
      'token_generation_buckets': [2048, 5120, 32768],
      'world_size': tp,
      'tp_degree': tp,
      'torch_dtype': 'bfloat16',
      'rpl_reduce_dtype': 'bfloat16',
      'attention_dtype': 'bfloat16',
      'cast_type': 'as-declared',
      'logical_neuron_cores': 2,
      'cc_pipeline_tiling_factor': 2,
      'fused_qkv': True,
      'qkv_kernel_enabled': True,
      'mlp_kernel_enabled': True,
      'attn_kernel_enabled': True
    },
    'vision_neuron_config': {
      'batch_size': 1,
      'seq_len': 16384,
      'max_context_length': 16384,
      'enable_bucketing': True,
      'buckets': [1024, 16384],
      'world_size': tp,
      'tp_degree': tp,
      'torch_dtype': 'bfloat16',
      'rpl_reduce_dtype': 'bfloat16',
      'cast_type': 'as-declared',
      'logical_neuron_cores': 2,
      'cc_pipeline_tiling_factor': 2,
      'fused_qkv': True,
      'attn_kernel_enabled': False,
      'mlp_kernel_enabled': False
    }
  }
}))
")

LIMIT_MM='{"image":20}'

mkdir -p /tmp/qwen3-warmup
LOG=/tmp/qwen3-warmup/qwen3.log
rm -f "$LOG"

echo "[INFO] launching vLLM warm-up (this populates Neuron compile cache, ~30-60 min)"
nohup vllm serve \
  --model="${MODEL_DIR}" \
  --tokenizer="${MODEL_DIR}" \
  --trust-remote-code \
  --dtype=bfloat16 \
  --tensor-parallel-size="${TP}" \
  --max-num-seqs=1 \
  --max-model-len=32768 \
  --additional-config="${ADDITIONAL_CONFIG}" \
  --limit-mm-per-prompt="${LIMIT_MM}" \
  --no-enable-chunked-prefill \
  --no-enable-prefix-caching \
  --host=0.0.0.0 \
  --port="${PORT}" >>"$LOG" 2>&1 &

VPID=$!
echo "[INFO] vllm pid=${VPID}"

ok=0
for i in $(seq 1 720); do
  if ! kill -0 "$VPID" 2>/dev/null; then
    echo "[NG] vllm exited prematurely"
    tail -100 "$LOG"
    exit 1
  fi
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health" || echo 000)
  if [ "$code" = "200" ]; then
    echo "[OK] /health=200 (attempt=${i})"
    ok=1
    break
  fi
  if [ $((i % 12)) -eq 0 ]; then
    echo "  [INFO] waiting (attempt=${i}, http=${code})"
    tail -3 "$LOG" | sed 's/^/    /'
  fi
  sleep 10
done

kill "$VPID" 2>/dev/null || true
for i in $(seq 1 30); do kill -0 "$VPID" 2>/dev/null || break; sleep 1; done
kill -9 "$VPID" 2>/dev/null || true

if [ "$ok" -ne 1 ]; then
  echo "[NG] warm-up did not become healthy in 7200s"
  tail -200 "$LOG"
  exit 1
fi

if [ ! -d "${COMPILE_CACHE}" ] || [ -z "$(ls -A "${COMPILE_CACHE}" 2>/dev/null)" ]; then
  echo "[NG] warm-up healthy but compile cache ${COMPILE_CACHE} empty -- refusing to write marker (would cause cold recompile after instance replacement)"
  exit 1
fi
date -u +'%Y-%m-%dT%H:%M:%SZ' > "${WARMUP_MARKER}"
echo "[OK] warm-up complete, compile cache populated on EFS, marker written"
