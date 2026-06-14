#!/usr/bin/env bash
set -euo pipefail

# Task: Print symlink summary + EFS usage
# 確認用に各 canonical path の symlink 情報と EFS の disk usage を出す。

echo '=== canonical paths ==='
for p in /models /opt/voice-image-edit /mnt/local/compiled_models /opt/dlami/nvme/qwen_image_edit_hf_cache_dir; do
  if [ -L "$p" ]; then echo "$p -> $(readlink -f "$p")"; else echo "[WARN] $p is not a symlink"; fi
done
echo
echo '=== EFS usage ==='
df -hT /mnt/efs | tail -1
du -sh "${EFS_ROOT}/${MODELS_DIR_NAME}"/* 2>/dev/null || true
du -sh "${EFS_ROOT}/${VIE_DIR_NAME}"/* 2>/dev/null || true
echo '[OK] setup-efs-paths complete'
