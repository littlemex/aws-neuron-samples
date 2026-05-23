#!/usr/bin/env bash
# CB が再作成された後、EFS から ephemeral storage に書き戻す。
# 起動前に必ず実行する想定。
#   bash efs/restore_from_efs.sh                  # 全部
#   bash efs/restore_from_efs.sh models           # /models のみ
#   bash efs/restore_from_efs.sh compiled         # compiled_models のみ
#   bash efs/restore_from_efs.sh cache            # neuron-cache のみ
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/efs_paths.sh"

TARGETS=("$@")
if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  TARGETS=(models compiled cache)
fi

run_rsync() {
  local src="$1" dst="$2" label="$3"
  if [[ ! -d "$src" ]]; then
    echo "[restore:$label] SKIP (no efs source yet): $src"
    return 0
  fi
  mkdir -p "$dst"
  echo "[restore:$label] $src -> $dst"
  rsync -aH --info=progress2 "$src/" "$dst/" || {
    echo "[restore:$label] FAIL"
    return 1
  }
  echo "[restore:$label] OK ($(du -sh "$dst" 2>/dev/null | awk '{print $1}'))"
}

rc=0
for t in "${TARGETS[@]}"; do
  case "$t" in
    models)   run_rsync "$EFS_MODELS"        "$LOCAL_MODELS"       models   || rc=1 ;;
    compiled) run_rsync "$EFS_COMPILED"      "$LOCAL_COMPILED"     compiled || rc=1 ;;
    cache)    run_rsync "$EFS_NEURON_CACHE"  "$LOCAL_NEURON_CACHE" cache    || rc=1 ;;
    *) echo "[restore] unknown target: $t" ; rc=1 ;;
  esac
done

echo "[restore] done rc=$rc"
exit $rc
