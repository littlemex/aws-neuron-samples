#!/usr/bin/env bash
set -euo pipefail

# Task: Verify all V3 CFG artifacts present
# Description: transformer_v3_cfg/ + vae_encoder/ + vae_decoder/ + language_model_v3/ + vision_encoder_v3/ が空でないことを確認。

for d in transformer_v3_cfg vae_encoder vae_decoder language_model_v3 vision_encoder_v3; do
  test -d "${COMPILED_MODELS_DIR}/$d" || { echo "[NG] missing $d"; exit 1; }
  count=$(ls -A "${COMPILED_MODELS_DIR}/$d" | wc -l)
  if [ "$count" -eq 0 ]; then echo "[NG] $d is empty"; exit 1; fi
  size=$(du -sh "${COMPILED_MODELS_DIR}/$d" | awk '{print $1}')
  echo "  [OK] $d ($size, $count entries)"
done

echo '[OK] all V3 CFG artifacts verified'
