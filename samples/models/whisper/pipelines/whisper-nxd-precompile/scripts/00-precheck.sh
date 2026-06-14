#!/usr/bin/env bash
set -euo pipefail

# NxD Inference の venv が存在し、neuronx_distributed_inference 自体が import できることを確認。
# Whisper modeling のフル import は openai-whisper に依存するためここでは行わず、
# 15-install-deps の後に実行する 30-compile に任せる。

test -x "${VENV}/bin/python" || { echo '[NG] venv missing: '"${VENV}"; exit 1; }
"${VENV}/bin/python" --version
export PATH="${VENV}/bin:$PATH"
# /models must be a symlink to EFS; setup-efs-paths is responsible for creating it.
# Running compile jobs without the symlink silently writes artifacts to EBS_root and
# they vanish on terminate.
test -L /models || { echo "[NG] /models is not a symlink. Run setup-efs-paths first."; exit 1; }
test -L /opt/voice-image-edit || { echo "[NG] /opt/voice-image-edit is not a symlink. Run setup-efs-paths first."; exit 1; }
"${VENV}/bin/python" -c 'import neuronx_distributed_inference; print("[OK] NxD Inference import")'
