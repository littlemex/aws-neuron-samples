#!/usr/bin/env bash
set -euo pipefail

# /models が directory + non-empty なら EFS に rsync。 既に symlink ならスキップ。

if [ -L /models ]; then echo '[OK] already symlinked'; exit 0; fi
if [ -d /models ] && [ "$(ls -A /models 2>/dev/null)" ]; then
  echo "[INFO] rsync /models -> ${EFS_ROOT}/${MODELS_DIR_NAME}"
  rsync -a --info=stats2,progress2 /models/ "${EFS_ROOT}/${MODELS_DIR_NAME}/"
  echo '[OK] /models rsync done'
else
  echo '[INFO] /models is empty or missing, skip'
fi
