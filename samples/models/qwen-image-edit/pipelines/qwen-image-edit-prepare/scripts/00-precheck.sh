#!/usr/bin/env bash
set -euo pipefail

# Task: Verify Neuron venv + nvme path
# Description: venv が存在し、 /mnt/local が存在することを確認 (compile artifact は nvme に置く)。

test -x "${VENV}/bin/python" || { echo '[NG] venv missing: '"${VENV}"; exit 1; }
"${VENV}/bin/python" --version
test -d /mnt/local || { echo '[NG] /mnt/local not found (DLAMI nvme partition is required)'; exit 1; }
command -v neuron-ls >/dev/null || echo '[WARN] neuron-ls not in PATH (continuing)'
echo '[OK] precheck'
