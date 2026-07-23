#!/usr/bin/env bash
# wait_ready.sh - poll until the server answers /v1/models, printing the elapsed
# time and whether the compile cache was hit (a warm restart logs
# "Local cache hit ... Skipping graph capture"). First-boot NEFF compilation on
# a single trn2.3xlarge takes minutes; a warm restart is much faster.
#
# Usage: ./wait_ready.sh <log-file> [port] [timeout-seconds]
set -euo pipefail
LOG="${1:?log file required}"
PORT="${2:-8000}"
TIMEOUT="${3:-900}"

start=$(date +%s)
while :; do
  now=$(date +%s)
  if curl -s "http://localhost:${PORT}/v1/models" -o /dev/null -w '%{http_code}' 2>/dev/null | grep -q 200; then
    echo "[ready] up after $((now-start))s"
    echo "[ready] compile-cache hits: $(grep -c 'Local cache hit' "${LOG}" 2>/dev/null || echo 0)"
    echo "[ready] compilations:       $(grep -c 'Compilation complete' "${LOG}" 2>/dev/null || echo 0)"
    exit 0
  fi
  if [ $((now-start)) -ge "${TIMEOUT}" ]; then
    echo "[ready] TIMEOUT after ${TIMEOUT}s" >&2
    tail -20 "${LOG}" >&2
    exit 1
  fi
  sleep 5
done
