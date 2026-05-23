#!/usr/bin/env bash
# CB terminate 前に「消えると困るもの」を EFS にバックアップする。
# 対象:
#   /models                        -> $EFS_MODELS
#   /opt/dlami/nvme/compiled_models -> $EFS_COMPILED
#   /var/tmp/neuron-compile-cache  -> $EFS_NEURON_CACHE  (任意, 存在すれば)
# 使い方:
#   bash efs/backup_to_efs.sh                        # 全部バックアップ
#   bash efs/backup_to_efs.sh models                 # /models のみ
#   bash efs/backup_to_efs.sh compiled               # compiled_models のみ
#   bash efs/backup_to_efs.sh cache                  # neuron-cache のみ
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck disable=SC1091
source "$HERE/efs_paths.sh"

TARGETS=("$@")
if [[ "${#TARGETS[@]}" -eq 0 ]]; then
  TARGETS=(models compiled cache)
fi

mkdir -p "$EFS_MODELS" "$EFS_COMPILED" "$EFS_NEURON_CACHE"

run_rsync() {
  local src="$1" dst="$2" label="$3"
  if [[ ! -d "$src" ]]; then
    echo "[backup:$label] SKIP (no source): $src"
    return 0
  fi
  echo "[backup:$label] $src -> $dst"
  # -a: archive, -H: hardlinks, --info=progress2 で 1 行進捗
  rsync -aH --delete --info=progress2 "$src/" "$dst/" || {
    echo "[backup:$label] FAIL"
    return 1
  }
  echo "[backup:$label] OK ($(du -sh "$dst" 2>/dev/null | awk '{print $1}'))"
}

rc=0
for t in "${TARGETS[@]}"; do
  case "$t" in
    models)   run_rsync "$LOCAL_MODELS"      "$EFS_MODELS"        models   || rc=1 ;;
    compiled) run_rsync "$LOCAL_COMPILED"    "$EFS_COMPILED"      compiled || rc=1 ;;
    cache)    run_rsync "$LOCAL_NEURON_CACHE" "$EFS_NEURON_CACHE" cache    || rc=1 ;;
    *) echo "[backup] unknown target: $t" ; rc=1 ;;
  esac
done

echo "[backup] done rc=$rc"
exit $rc
