#!/usr/bin/env bash
set -euo pipefail

# Task: Fetch compile_xttsv2_nxd.py + neuron_xttsv2/ tarball
# Description: Pull the source tarball produced by deploy-all.sh from its presigned S3 URL
# and extract under WORK_DIR. The tarball is mounted read-only into the DLC at /src.

if [ -f "${COMPILED_MODEL_PATH}/.precompile_skipped" ] && [ "${FORCE_RECOMPILE}" != 'true' ]; then
  echo '[OK] skipped (cached)'
  exit 0
fi

test -n "${SOURCE_TARBALL_URL}" || { echo '[NG] SOURCE_TARBALL_URL is empty'; exit 1; }

mkdir -p "${WORK_DIR}"
rm -rf "${WORK_DIR}/source"
mkdir -p "${WORK_DIR}/source"

tmp=$(mktemp /tmp/xttsv2-source.XXXXXX.tar.gz)
trap 'rm -f $tmp' EXIT

curl -fsSL "${SOURCE_TARBALL_URL}" -o "$tmp"
tar -C "${WORK_DIR}/source" -xzf "$tmp"

test -f "${WORK_DIR}/source/compile_xttsv2_nxd.py" \
  || { echo '[NG] compile_xttsv2_nxd.py missing after extract'; exit 1; }
test -d "${WORK_DIR}/source/neuron_xttsv2" \
  || { echo '[NG] neuron_xttsv2/ missing after extract'; exit 1; }

echo '[OK] source extracted'
