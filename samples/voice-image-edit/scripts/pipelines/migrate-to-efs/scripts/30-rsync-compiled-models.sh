#!/usr/bin/env bash
set -euo pipefail

# compile.sh 出力の本体。 NVMe -> EFS の rsync は大きいので時間がかかる (~10 min for 80GB)。
# SSM の TASK_MAX_WAIT_SECONDS を大きくすること。

SRC=/mnt/local/compiled_models
TARGET="${EFS_ROOT}/${MODELS_DIR_NAME}/qwen-image-edit-compiled"

if [ -L "$SRC" ]; then echo '[OK] already symlinked'; exit 0; fi
if [ -d "$SRC" ] && [ "$(ls -A "$SRC" 2>/dev/null)" ]; then
  mkdir -p "$TARGET"
  echo '[INFO] rsync (this can take ~10 min for ~80GB)'
  rsync -a --info=stats2,progress2 "$SRC/" "$TARGET/"
  echo '[OK] compiled_models rsync done'
else
  echo '[INFO] compiled_models empty/missing, skip'
fi
