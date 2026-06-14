#!/usr/bin/env bash
set -euo pipefail

# /mnt/efs が mount 済で、 移行元 directory のいずれかが存在することを確認する。
# 全部存在しなければ migrate 不要なので exit 0。

mountpoint -q /mnt/efs || { echo '[NG] /mnt/efs not mounted'; exit 1; }

any=0
for p in /models /opt/voice-image-edit /mnt/local/compiled_models /opt/dlami/nvme/qwen_image_edit_hf_cache_dir; do
  if [ -d "$p" ] && [ ! -L "$p" ] && [ "$(ls -A "$p" 2>/dev/null)" ]; then any=1; echo "[INFO] need migrate: $p"; fi
done

if [ "$any" -eq 0 ]; then echo '[OK] nothing to migrate'; exit 0; fi
echo '[OK] some sources need migration'
