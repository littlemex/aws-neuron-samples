#!/usr/bin/env bash
set -euo pipefail

# DLAMI に同梱された vLLM/Neuron venv の python が存在することを確認。

test -x "${VENV}/bin/python" || { echo "[NG] venv missing: ${VENV}"; exit 1; }
"${VENV}/bin/python" --version
"${VENV}/bin/python" -c 'import vllm; print("vllm", vllm.__version__)'
echo "[OK] precheck"
