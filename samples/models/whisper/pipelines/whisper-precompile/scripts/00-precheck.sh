#!/usr/bin/env bash
set -euo pipefail

# DLAMI に同梱された Neuron 仮想環境と neuron-ls が存在することを確認する。

test -x "${VENV}/bin/python" || { echo '[NG] venv missing: '"${VENV}"; exit 1; }
"${VENV}/bin/python" --version
command -v neuron-ls >/dev/null || echo '[WARN] neuron-ls not in PATH (continuing)'
# /models must be a symlink to EFS; setup-efs-paths is responsible for creating it.
# Running compile jobs without the symlink silently writes artifacts to EBS_root and
# they vanish on terminate.
test -L /models || { echo "[NG] /models is not a symlink. Run setup-efs-paths first."; exit 1; }
test -L /opt/voice-image-edit || { echo "[NG] /opt/voice-image-edit is not a symlink. Run setup-efs-paths first."; exit 1; }
echo '[OK] precheck'
