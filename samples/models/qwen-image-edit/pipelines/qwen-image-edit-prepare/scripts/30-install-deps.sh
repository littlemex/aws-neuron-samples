#!/usr/bin/env bash
set -euo pipefail

# Task: Install Python deps for compile (diffusers, transformers, etc.)
# Description: venv に compile に必要な diffusers/transformers/accelerate/qwen-vl-utils を入れる。 huggingface_hub は既存。

if [ -f "${COMPILED_MODELS_DIR}/.precompile_skipped" ] && [ "${FORCE_RECOMPILE}" != 'true' ]; then
  echo '[OK] skipped (cached)'
  exit 0
fi

. "${VENV}/bin/activate"

"${VENV}/bin/pip" install --quiet \
  'git+https://github.com/huggingface/diffusers' \
  'transformers>=4.45.0' \
  'accelerate' \
  'qwen-vl-utils' \
  'torchvision' \
  'pillow' \
  2>&1 | tail -10 || true

"${VENV}/bin/python" -c 'import diffusers, transformers; print("diffusers", diffusers.__version__); print("transformers", transformers.__version__)'

echo '[OK] deps installed'
