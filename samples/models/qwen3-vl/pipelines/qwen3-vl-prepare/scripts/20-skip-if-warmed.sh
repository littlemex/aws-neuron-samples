#!/usr/bin/env bash
set -euo pipefail

# Skip warmup if both the marker file and a non-empty compile cache exist.
# If only the marker is present but the compile cache is missing or empty
# (e.g. NVMe was wiped on instance replacement), re-warm to repopulate it.
# FORCE_REWARMUP=true bypasses the cache check unconditionally.

if [ "${FORCE_REWARMUP}" = "true" ]; then
  echo "[INFO] FORCE_REWARMUP=true, will warm up"
  exit 0
fi

if [ -f "${WARMUP_MARKER}" ] && [ -d "${COMPILE_CACHE}" ] && [ -n "$(ls -A "${COMPILE_CACHE}" 2>/dev/null)" ]; then
  echo "[OK] warmup already done (marker + non-empty compile cache present) at:"
  cat "${WARMUP_MARKER}"
  touch "${MODEL_DIR}/.precompile_skipped"
  exit 0
fi

if [ -f "${WARMUP_MARKER}" ]; then
  echo "[WARN] warmup marker present but compile cache ${COMPILE_CACHE} is missing/empty (NVMe wiped on instance replacement?) -- re-warming"
  rm -f "${MODEL_DIR}/.precompile_skipped"
fi

echo "[INFO] no valid warmup, will run vLLM warmup"
