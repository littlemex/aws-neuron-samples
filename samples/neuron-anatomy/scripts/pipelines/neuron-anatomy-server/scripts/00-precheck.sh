#!/usr/bin/env bash
set -euo pipefail

# Task: 00-precheck
# Name: Precheck python3 + curl + tar + neuron-ls
# Description: Confirm the runtime tools we need are present.
#              neuron-monitor / neuron-ls are required by the backend at request time.

command -v python3 >/dev/null || { echo '[NG] python3 missing'; exit 1; }
python3 --version
command -v curl >/dev/null || { echo '[NG] curl missing'; exit 1; }
command -v tar >/dev/null || { echo '[NG] tar missing'; exit 1; }
id "${SERVE_USER}" >/dev/null 2>&1 || { echo "[NG] user ${SERVE_USER} missing"; exit 1; }
python3 -m venv --help >/dev/null 2>&1 || { echo '[NG] python3-venv module missing; run: apt-get install python3-venv'; exit 1; }
test -x "${NEURON_LS_BIN}" || { echo "[NG] ${NEURON_LS_BIN} missing — install aws-neuronx-tools"; exit 1; }
test -x "${NEURON_MONITOR_BIN}" || { echo "[NG] ${NEURON_MONITOR_BIN} missing — install aws-neuronx-tools"; exit 1; }
echo '[OK] precheck'
