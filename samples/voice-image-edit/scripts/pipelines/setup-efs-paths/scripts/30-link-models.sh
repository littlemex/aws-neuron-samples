#!/usr/bin/env bash
set -euo pipefail

# Task: Symlink /models -> EFS/models
# /models が directory ならその中身を EFS に rsync してから symlink に張り替える。
# 既に EFS 向き symlink ならスキップ。

TARGET="${EFS_ROOT}/${MODELS_DIR_NAME}"
if [ -L /models ]; then
  current=$(readlink -f /models)
  if [ "$current" = "$TARGET" ]; then echo '[OK] /models already symlinked'; exit 0; fi
  echo "[INFO] /models points to $current, retargeting"; rm /models
elif [ -d /models ] && [ "$(ls -A /models 2>/dev/null)" ]; then
  echo '[INFO] migrating /models contents to EFS'
  rsync -a --info=progress2 /models/ "${TARGET}/"
  rm -rf /models
elif [ -d /models ]; then
  rmdir /models 2>/dev/null || rm -rf /models
fi
ln -sfn "${TARGET}" /models
ls -ld /models
echo '[OK] /models -> EFS'
