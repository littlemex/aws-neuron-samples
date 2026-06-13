#!/usr/bin/env bash
set -euo pipefail

# Task: Verify docker + Neuron device + compiled artefacts + checkpoint
# Compiled artefacts must exist (run xttsv2-precompile first).
# Docker daemon must be active and /dev/neuron0 must be present.

command -v docker >/dev/null || { echo '[NG] docker not installed'; exit 1; }
systemctl is-active docker.service >/dev/null 2>&1 || { echo '[NG] docker.service not active'; exit 1; }
test -e /dev/neuron0 || { echo '[NG] /dev/neuron0 missing'; exit 1; }
test -f "${COMPILED_MODEL_PATH}/.compile_metadata.json" || { echo '[NG] .compile_metadata.json missing — run xttsv2-precompile.json first'; exit 1; }
test -d "${COMPILED_MODEL_PATH}/prefill" || { echo '[NG] prefill/ missing'; exit 1; }
test -d "${COMPILED_MODEL_PATH}/decode" || { echo '[NG] decode/ missing'; exit 1; }
test -f "${XTTS_MODEL_DIR}/model.pth" || { echo "[NG] ${XTTS_MODEL_DIR}/model.pth missing"; exit 1; }
test -f "${XTTS_MODEL_DIR}/config.json" || { echo "[NG] ${XTTS_MODEL_DIR}/config.json missing"; exit 1; }
id "${SERVE_USER}" >/dev/null 2>&1 || { echo "[NG] user ${SERVE_USER} missing"; exit 1; }
echo '[OK] precheck'
