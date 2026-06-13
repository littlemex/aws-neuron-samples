#!/usr/bin/env bash
set -euo pipefail

# Task: 30-create-venv
# Name: Create venv + pip install (fastapi, uvicorn, pydantic)
# Description: Standalone venv for the anatomy backend so we never collide with
#              the Neuron model server venvs (which carry torch/diffusers and are large).

apt-get -y install python3-venv || { echo '[NG] apt-get install python3-venv failed'; exit 1; }
if [ ! -x "${VENV}/bin/python" ]; then python3 -m venv "${VENV}"; fi
"${VENV}/bin/pip" install --upgrade pip --quiet
"${VENV}/bin/pip" install --quiet -r "${SERVE_DIR}/backend/requirements.txt"
chown -R "${SERVE_USER}:${SERVE_USER}" "${VENV}"
"${VENV}/bin/python" -c 'import fastapi, uvicorn, pydantic; print("deps OK")'
echo '[OK] venv ready'
