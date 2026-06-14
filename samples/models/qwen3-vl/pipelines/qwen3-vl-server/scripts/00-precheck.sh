#!/usr/bin/env bash
set -euo pipefail

# Task: Verify venv + warmed model dir
# Description: venv と warm-up marker (.neuron_warmup_done) があること。 model dir に config.json があること。

test -x "${VENV}/bin/python" || { echo "[NG] venv missing: ${VENV}"; exit 1; }
test -f "${MODEL_DIR}/config.json" || { echo "[NG] ${MODEL_DIR}/config.json missing — run qwen3-vl-prepare.json first"; exit 1; }
test -f "${MODEL_DIR}/.neuron_warmup_done" || { echo "[NG] ${MODEL_DIR}/.neuron_warmup_done missing — run qwen3-vl-prepare.json first"; exit 1; }
id "${SERVE_USER}" >/dev/null 2>&1 || { echo "[NG] user ${SERVE_USER} missing"; exit 1; }
echo '[OK] precheck'
