#!/usr/bin/env bash
set -euo pipefail

# EFS 上に rsync 先 directory を作る。

mkdir -p "${EFS_ROOT}/${MODELS_DIR_NAME}" "${EFS_ROOT}/${VIE_DIR_NAME}"
echo '[OK] EFS dirs ensured'
