#!/usr/bin/env bash
set -euo pipefail

# Task: 30-install-deps
# Description: venv に diffusers/transformers/fastapi/uvicorn が無ければ入れる。compile タスク後なので大半は既存。

# shellcheck source=/dev/null
. "${VENV}/bin/activate"

"${VENV}/bin/pip" install --quiet \
  'fastapi' \
  'uvicorn[standard]' \
  'python-multipart' \
  'qwen-vl-utils' \
  'git+https://github.com/huggingface/diffusers' \
  'transformers>=4.45.0' \
  2>&1 | tail -5 || true

"${VENV}/bin/python" -c 'import fastapi, uvicorn, diffusers, transformers; print("fastapi", fastapi.__version__)'

echo "[OK] deps installed"
