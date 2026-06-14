#!/usr/bin/env bash
set -euo pipefail

# DLAMI に同梱された vLLM/Neuron venv の python が存在することを確認。

test -x "${VENV}/bin/python" || { echo "[NG] venv missing: ${VENV}"; exit 1; }
"${VENV}/bin/python" --version
"${VENV}/bin/python" -c 'import vllm; print("vllm", vllm.__version__)'
# /models must be a symlink to EFS; setup-efs-paths is responsible for creating it.
# Running compile jobs without the symlink silently writes artifacts to EBS_root and
# they vanish on terminate.
test -L /models || { echo "[NG] /models is not a symlink. Run setup-efs-paths first."; exit 1; }
echo "[OK] precheck"
