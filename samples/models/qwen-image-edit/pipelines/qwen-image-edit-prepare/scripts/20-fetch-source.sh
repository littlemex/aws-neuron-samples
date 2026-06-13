#!/usr/bin/env bash
set -euo pipefail

# Task: Fetch source tarball (compile.sh + neuron_qwen_image_edit/ + run_qwen_image_edit.py + serve.py)
# Description: presigned S3 URL から tarball を WORK_DIR に展開。

if [ -f "${COMPILED_MODELS_DIR}/.precompile_skipped" ] && [ "${FORCE_RECOMPILE}" != 'true' ]; then
  echo '[OK] skipped (cached)'
  exit 0
fi

test -n "${SOURCE_TARBALL_URL}" || { echo '[NG] SOURCE_TARBALL_URL is empty'; exit 1; }

mkdir -p "${WORK_DIR}"
rm -rf "${WORK_DIR:?}"/*

tmp=$(mktemp /tmp/qwen-image-edit-src.XXXXXX.tar.gz)
trap 'rm -f "$tmp"' EXIT

curl -fsSL "${SOURCE_TARBALL_URL}" -o "$tmp"
tar -C "${WORK_DIR}" -xzf "$tmp"

test -f "${WORK_DIR}/compile.sh" || { echo '[NG] compile.sh missing after extract'; exit 1; }
test -d "${WORK_DIR}/neuron_qwen_image_edit" || { echo '[NG] neuron_qwen_image_edit/ missing'; exit 1; }
test -f "${WORK_DIR}/serve.py" || { echo '[NG] serve.py missing'; exit 1; }

echo "[OK] source extracted to ${WORK_DIR}"
