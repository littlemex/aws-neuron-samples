#!/usr/bin/env bash
set -euo pipefail

# NxD Inference の venv が存在し、neuronx_distributed_inference 自体が import できることを確認。
# Whisper modeling のフル import は openai-whisper に依存するためここでは行わず、
# 15-install-deps の後に実行する 30-compile に任せる。

test -x "${VENV}/bin/python" || { echo '[NG] venv missing: '"${VENV}"; exit 1; }
"${VENV}/bin/python" --version
export PATH="${VENV}/bin:$PATH"
"${VENV}/bin/python" -c 'import neuronx_distributed_inference; print("[OK] NxD Inference import")'
