#!/usr/bin/env bash
set -euo pipefail

# Task: Skip if all V3 CFG artifacts already exist
# Description: transformer_v3_cfg/ + vae_encoder/ + vae_decoder/ + language_model_v3/ + vision_encoder_v3/ が揃っていれば exit 0。

if [ "${FORCE_RECOMPILE}" = 'true' ]; then echo '[INFO] FORCE_RECOMPILE=true, will recompile'; exit 0; fi

missing=0
for d in transformer_v3_cfg vae_encoder vae_decoder language_model_v3 vision_encoder_v3; do
  if [ ! -d "${COMPILED_MODELS_DIR}/$d" ] || [ -z "$(ls -A "${COMPILED_MODELS_DIR}/$d" 2>/dev/null)" ]; then
    echo "[INFO] missing artifact dir: $d"
    missing=1
  fi
done

if [ $missing -eq 0 ]; then
  echo '[OK] all artifacts present, skip compile'
  mkdir -p "${COMPILED_MODELS_DIR}"
  touch "${COMPILED_MODELS_DIR}/.precompile_skipped"
  exit 0
fi
echo '[INFO] some artifacts missing, will compile'
