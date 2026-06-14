#!/usr/bin/env bash
set -euo pipefail

# WARMUP_MARKER があれば cache populate 済みとみなして skip。
# FORCE_REWARMUP=true で明示的に再実行可。

if [ "${FORCE_REWARMUP}" = "true" ]; then
  echo "[INFO] FORCE_REWARMUP=true, will warm up"
  exit 0
fi

if [ -f "${WARMUP_MARKER}" ]; then
  echo "[OK] warmup already done at:"
  cat "${WARMUP_MARKER}"
  touch "${MODEL_DIR}/.precompile_skipped"
  exit 0
fi

echo "[INFO] no warmup marker, will run vLLM warmup"
