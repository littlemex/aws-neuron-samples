#!/usr/bin/env bash
set -euo pipefail

# Task: 00-precheck
# Description: venv と compile artifact (transformer_v3_cfg/ 等) が compiled_models_tp16/ 下にあること。

test -x "${VENV}/bin/python" || { echo "[NG] venv missing: ${VENV}"; exit 1; }

for d in transformer_v3_cfg vae_encoder vae_decoder language_model_v3 vision_encoder_v3; do
  test -d "${COMPILED_MODELS_DIR}/$d" || { echo "[NG] ${COMPILED_MODELS_DIR}/$d missing — run qwen-image-edit-prepare pipeline first"; exit 1; }
done

id "${SERVE_USER}" >/dev/null 2>&1 || { echo "[NG] user ${SERVE_USER} missing"; exit 1; }

echo "[OK] precheck"
