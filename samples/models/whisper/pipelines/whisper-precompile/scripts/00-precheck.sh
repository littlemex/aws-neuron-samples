#!/usr/bin/env bash
set -euo pipefail

# DLAMI に同梱された Neuron 仮想環境と neuron-ls が存在することを確認する。

test -x "${VENV}/bin/python" || { echo '[NG] venv missing: '"${VENV}"; exit 1; }
"${VENV}/bin/python" --version
command -v neuron-ls >/dev/null || echo '[WARN] neuron-ls not in PATH (continuing)'
echo '[OK] precheck'
