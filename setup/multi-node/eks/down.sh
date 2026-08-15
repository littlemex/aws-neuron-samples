#!/usr/bin/env bash
# Tear down a serving workload deployed by up.sh.
#
#   ./down.sh <model-preset> [--namespace NS] [--context CTX] [--keep-cache]
#
# By default the cache PVC is deleted too. --keep-cache preserves it (and the compiled NEFF /
# downloaded weights on the bound PV) so the next up.sh skips the cold recompile.
set -euo pipefail
cd "$(dirname "$0")"

PRESET="${1:-}"; shift || true
[ -n "$PRESET" ] || { echo "usage: ./down.sh <model-preset> [--namespace NS] [--context CTX] [--keep-cache]"; exit 2; }
NAME="$PRESET"; NS=default; CTX=""; KEEP=0
while [ $# -gt 0 ]; do case "$1" in
  --namespace) NS="$2"; shift 2;;
  --context) CTX="$2"; shift 2;;
  --keep-cache) KEEP=1; shift;;
  *) echo "unknown option: $1"; exit 2;;
esac; done

KUBECTL=(kubectl); [ -n "$CTX" ] && KUBECTL=(kubectl --context "$CTX")
echo "[down] deleting workload '$NAME' in namespace '$NS'"
"${KUBECTL[@]}" -n "$NS" delete deploy,svc -l "app=$NAME" --ignore-not-found
if [ "$KEEP" = 1 ]; then
  echo "[down] keeping cache PVC (${NAME}-cache)"
else
  "${KUBECTL[@]}" -n "$NS" delete pvc "${NAME}-cache" --ignore-not-found
fi
echo "[down] done."
