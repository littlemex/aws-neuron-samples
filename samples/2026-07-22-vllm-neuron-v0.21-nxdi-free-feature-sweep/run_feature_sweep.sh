#!/usr/bin/env bash
# run_feature_sweep.sh - entrypoint for the vLLM Neuron v0.21 feature sweep.
#
#   ./run_feature_sweep.sh cpu     # run the CPU-only checks (no NeuronCore)
#   ./run_feature_sweep.sh help    # print the server-based recipes
#
# Server-based checks (segmented prefill, prefix caching, structured outputs,
# GPT-OSS MoE, EP, EAGLE3, multimodal) each need a server launched with a
# feature-specific config; see README.md and the header of each verify/ script.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
VENV="${VLLM_NEURON_VENV:-/opt/aws_neuronx_venv_pytorch_inference_vllm_0_21_0_1_0_0}"
PY="${VENV}/bin/python3"

case "${1:-help}" in
  cpu)
    echo "== CPU mode + NKI CPU simulator (no NeuronCore) =="
    VLLM_NEURON_CPU_MODE=1 NKI_SIMULATOR=1 "${PY}" "${HERE}/verify/cpu_nki_simulator.py"
    echo
    echo "== Out-of-tree onboarding (SyntheticNeuronModel, CPU mode) =="
    VLLM_NEURON_CPU_MODE=1 VLLM_NEURON_SYNTHETIC_MODEL=1 VLLM_ENABLE_V1_MULTIPROCESSING=0 \
      "${PY}" "${HERE}/verify/oot_synthetic_e2e.py"
    ;;
  help|*)
    sed -n '2,12p' "$0"
    echo
    echo "See README.md for server launch recipes and verify/ script headers."
    ;;
esac
