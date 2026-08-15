#!/usr/bin/env bash
# One-shot: deploy a vLLM Neuron serving workload for <model-preset> onto an existing
# distributed-ai/infra/eks cluster. Renders chart/ with models/<preset>.yaml and applies it.
#
#   ./up.sh <model-preset> [options]
#
# Options:
#   --pool NAME        node-role of the target Karpenter Neuron pool (default: trn2)
#   --namespace NS     Kubernetes namespace (default: default)
#   --nodes N          multinode topology with N chips (default: preset/chart value; single-node otherwise)
#   --volume PV        infra static PV to bind the NEFF/weights cache (default: openzfs-shared)
#   --storage-class SC dynamic (multi-tenant) cache class, e.g. efs-sc; each deploy gets its own PVC
#   --context CTX      kubectl context
#   --set K=V          extra helm --set override (repeatable)
#   --dry-run          print the rendered manifest and exit (no apply)
#   --no-wait          apply without waiting for readiness
#
# Example:
#   ./up.sh qwen3-vl --pool trn2 --namespace serving
set -euo pipefail
cd "$(dirname "$0")"

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; }
PRESET="${1:-}"; shift || true
[ -n "$PRESET" ] || { usage; echo; echo "error: model preset required (see models/)"; exit 2; }
PRESET_FILE="models/${PRESET}.yaml"
[ -f "$PRESET_FILE" ] || { echo "error: no preset $PRESET_FILE. Available:"; ls models/*.yaml 2>/dev/null | sed 's#models/##;s#\.yaml##;s/^/  - /'; exit 2; }

POOL=trn2; NS=default; NODES=""; VOLUME=""; SC=""; CTX=""; DRYRUN=0; WAIT=1; EXTRA=()
while [ $# -gt 0 ]; do case "$1" in
  --pool) POOL="$2"; shift 2;;
  --namespace) NS="$2"; shift 2;;
  --nodes) NODES="$2"; shift 2;;
  --volume) VOLUME="$2"; shift 2;;
  --storage-class) SC="$2"; shift 2;;
  --context) CTX="$2"; shift 2;;
  --set) EXTRA+=(--set "$2"); shift 2;;
  --dry-run) DRYRUN=1; shift;;
  --no-wait) WAIT=0; shift;;
  *) echo "unknown option: $1"; exit 2;;
esac; done

command -v helm >/dev/null || { echo "error: helm not found"; exit 1; }
command -v kubectl >/dev/null || { echo "error: kubectl not found"; exit 1; }
KUBECTL=(kubectl); [ -n "$CTX" ] && KUBECTL=(kubectl --context "$CTX")

NAME="$PRESET"
SETS=(--set "name=$NAME" --set "namespace=$NS" --set "pool=$POOL")
[ -n "$NODES" ] && SETS+=(--set "nodes=$NODES" --set "topology=multinode")
[ -n "$VOLUME" ] && SETS+=(--set "cache.volumeName=$VOLUME")
# Dynamic (multi-tenant) cache: a storage class + empty volumeName -> each deployment gets its own
# isolated PVC (e.g. an EFS access point). Overrides any static volumeName.
[ -n "$SC" ] && SETS+=(--set "cache.storageClassName=$SC" --set "cache.volumeName=")

render() { helm template "$NAME" chart/ -f "$PRESET_FILE" "${SETS[@]}" "${EXTRA[@]}"; }

if [ "$DRYRUN" = 1 ]; then render; exit 0; fi

echo "[up] deploying '$NAME' (preset=$PRESET pool=$POOL ns=$NS ${NODES:+nodes=$NODES})"
"${KUBECTL[@]}" get ns "$NS" >/dev/null 2>&1 || "${KUBECTL[@]}" create ns "$NS"
render | "${KUBECTL[@]}" apply -f -

if [ "$WAIT" = 1 ]; then
  echo "[up] waiting for readiness (first boot compiles the model; this can take many minutes)..."
  "${KUBECTL[@]}" -n "$NS" rollout status deploy/"$NAME" --timeout=45m || {
    echo "[up] not ready yet; inspect: kubectl -n $NS logs deploy/$NAME"; exit 1; }
  echo "[up] ready. Service '$NAME' in namespace '$NS' (port 8000)."
else
  echo "[up] applied (not waiting). Watch: kubectl -n $NS logs -f deploy/$NAME"
fi
echo "     port-forward: kubectl -n $NS port-forward svc/$NAME 8000:8000"
echo "     then: curl localhost:8000/v1/models"
