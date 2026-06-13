#!/usr/bin/env bash
set -euo pipefail

# HF download (Qwen-Image-Edit-2511 + Qwen3-VL-8B-Instruct + tokenizers) の本体。
# ~110GB なので ~15 min かかる。

SRC=/opt/dlami/nvme/qwen_image_edit_hf_cache_dir
TARGET="${EFS_ROOT}/${MODELS_DIR_NAME}/hf-cache"

if [ -L "$SRC" ]; then echo '[OK] already symlinked'; exit 0; fi
if [ -d "$SRC" ] && [ "$(ls -A "$SRC" 2>/dev/null)" ]; then
  mkdir -p "$TARGET"
  echo '[INFO] rsync (this can take ~15 min for ~110GB)'
  rsync -a --info=stats2,progress2 "$SRC/" "$TARGET/"
  echo '[OK] hf-cache rsync done'
else
  echo '[INFO] hf-cache empty/missing, skip'
fi
