#!/usr/bin/env bash
set -euo pipefail

# Task: Symlink HF cache -> EFS/models/hf-cache
# compile.sh と serve.py が見る HF_HOME / HUGGINGFACE_CACHE_DIR の親
# (/opt/dlami/nvme/qwen_image_edit_hf_cache_dir) を EFS に向ける。
# 既存の HF download (~110GB) があれば EFS に rsync する。

SRC=/opt/dlami/nvme/qwen_image_edit_hf_cache_dir
TARGET="${EFS_ROOT}/${MODELS_DIR_NAME}/hf-cache"
if [ -L "$SRC" ]; then
  current=$(readlink -f "$SRC")
  if [ "$current" = "$TARGET" ]; then echo '[OK] hf-cache already symlinked'; exit 0; fi
  rm "$SRC"
elif [ -d "$SRC" ] && [ "$(ls -A "$SRC" 2>/dev/null)" ]; then
  echo '[INFO] migrating HF cache to EFS (this may take ~15 min for ~110GB)'
  rsync -a --info=progress2 "$SRC/" "${TARGET}/"
  rm -rf "$SRC"
elif [ -d "$SRC" ]; then
  rmdir "$SRC" 2>/dev/null || rm -rf "$SRC"
fi
mkdir -p "$(dirname "$SRC")"
ln -sfn "${TARGET}" "$SRC"
ls -ld "$SRC"
echo '[OK] hf-cache -> EFS'
