#!/usr/bin/env bash
set -euo pipefail

# Task: Symlink /mnt/local/compiled_models -> EFS/models/qwen-image-edit-compiled
# compile.sh は /mnt/local/compiled_models/ を出力先にハードコードしているので、
# そこを EFS の qwen-image-edit-compiled/ に link する。
# NVMe 上の既存内容があれば一旦 EFS に rsync する。

TARGET="${EFS_ROOT}/${MODELS_DIR_NAME}/qwen-image-edit-compiled"
if [ -L /mnt/local/compiled_models ]; then
  current=$(readlink -f /mnt/local/compiled_models)
  if [ "$current" = "$TARGET" ]; then echo '[OK] compiled_models already symlinked'; exit 0; fi
  rm /mnt/local/compiled_models
elif [ -d /mnt/local/compiled_models ] && [ "$(ls -A /mnt/local/compiled_models 2>/dev/null)" ]; then
  echo '[INFO] migrating compiled_models to EFS (this may take ~10 min for ~80GB)'
  rsync -a --info=progress2 /mnt/local/compiled_models/ "${TARGET}/"
  rm -rf /mnt/local/compiled_models
elif [ -d /mnt/local/compiled_models ]; then
  rmdir /mnt/local/compiled_models 2>/dev/null || rm -rf /mnt/local/compiled_models
fi
ln -sfn "${TARGET}" /mnt/local/compiled_models
ls -ld /mnt/local/compiled_models
echo '[OK] /mnt/local/compiled_models -> EFS'
