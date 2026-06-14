#!/usr/bin/env bash
set -euo pipefail

# rsync 後の EFS 占有を表示する。

echo '=== EFS usage ==='
df -hT /mnt/efs | tail -1
du -sh "${EFS_ROOT}"/* 2>/dev/null || true
du -sh "${EFS_ROOT}/${MODELS_DIR_NAME}"/* 2>/dev/null || true
du -sh "${EFS_ROOT}/${VIE_DIR_NAME}"/* 2>/dev/null || true
echo '[OK] migrate complete - run setup-efs-paths.json next to flip symlinks'
