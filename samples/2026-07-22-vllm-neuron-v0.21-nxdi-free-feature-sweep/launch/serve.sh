#!/usr/bin/env bash
# serve.sh - launch a vLLM Neuron OpenAI-compatible server with the operational
# lessons from the v0.21 feature sweep baked in.
#
# Encodes three things that are easy to get wrong on a single trn2.3xlarge:
#   1. NeuronCores are released ~30-45s AFTER a vLLM process dies, and the worker
#      processes are named "VLLM::Worker_TP*" / "VLLM::EngineCore" (NOT
#      "vllm.entrypoints"), so a naive `pkill -f vllm.entrypoints` leaves zombies
#      holding the cores and the next launch fails with "cores busy (ret=-16)".
#   2. This instance has no EFA-type ENI, so EFA affinity must be skipped.
#   3. The compile-cache location is controlled by VLLM_CACHE_ROOT (NOT the
#      NEURON_COMPILED_ARTIFACTS that the docs mention, which is a no-op).
#
# Usage:
#   ./serve.sh --cache-root /work/cache --log /tmp/srv.log -- \
#       --model meta-llama/Llama-3.1-8B-Instruct --tensor-parallel-size 4 ...
#
# Everything after `--` is passed verbatim to `vllm.entrypoints.openai.api_server`.
set -euo pipefail

VENV="${VLLM_NEURON_VENV:-/opt/aws_neuronx_venv_pytorch_inference_vllm_0_21_0_1_0_0}"
NEURON_BIN="/opt/aws/neuron/bin"
CACHE_ROOT="/work/vllm_cache"
LOG="/tmp/vllm_server.log"
PORT="8000"

ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cache-root) CACHE_ROOT="$2"; shift 2 ;;
    --log) LOG="$2"; shift 2 ;;
    --) shift; ARGS=("$@"); break ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

export PATH="${NEURON_BIN}:${VENV}/bin:${PATH}"
export NEURON_SKIP_EFA_AFFINITY=1          # no EFA ENI on trn2.3xlarge
export VLLM_CACHE_ROOT="${CACHE_ROOT}"     # the real compile-cache knob
mkdir -p "${CACHE_ROOT}"

echo "[serve] freeing NeuronCores (killing any VLLM:: workers)..."
pkill -9 -f "VLLM::"          2>/dev/null || true
pkill -9 -f "vllm.entrypoints" 2>/dev/null || true
pkill -9 -f "neuronx-cc"       2>/dev/null || true
# also kill by the PID column that neuron-ls reports as holding a core
for pid in $(neuron-ls 2>/dev/null | grep -oE "\| [0-9]{3,} " | tr -d '| '); do
  kill -9 "$pid" 2>/dev/null || true
done

# wait until no vLLM/compiler process remains (cores genuinely free)
for _ in $(seq 1 20); do
  if [ "$(pgrep -fc 'VLLM::|vllm.entrypoints|neuronx-cc' || true)" = "0" ]; then break; fi
  sleep 3
done
sleep 10   # Neuron runtime lags process death; give it margin

echo "[serve] launching: ${ARGS[*]}"
nohup python3 -m vllm.entrypoints.openai.api_server "${ARGS[@]}" > "${LOG}" 2>&1 &
echo "[serve] pid=$! log=${LOG} cache=${CACHE_ROOT}"
