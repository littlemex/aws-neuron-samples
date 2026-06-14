#!/usr/bin/env bash
set -euo pipefail

# Task: Ensure ${SWAP_SIZE_GB}GB swap is available
# Description: XTTSv2 compile traces ~3GB tensors and OOMs without swap on trn2.3xlarge.
# We allocate ${SWAP_SIZE_GB}GB on first run; if ${SWAP_FILE} already exists the step is a no-op.

if swapon --show=NAME --noheadings 2>/dev/null | grep -q "^${SWAP_FILE}$"; then
  echo '[OK] swap already on'
  exit 0
fi

if [ ! -f "${SWAP_FILE}" ]; then
  fallocate -l "${SWAP_SIZE_GB}G" "${SWAP_FILE}"
  chmod 600 "${SWAP_FILE}"
  mkswap "${SWAP_FILE}"
fi

swapon "${SWAP_FILE}"
free -h | grep -i swap
echo "[OK] swap on at ${SWAP_FILE}"
