#!/usr/bin/env bash
# 3 モデル一撃動作確認 (内部で ../models/<name>/test.sh を呼ぶ)
# 各テストは独立して終了コード 0/1 を返す。本スクリプトは合計でレポートする。
set -uo pipefail

QWEN3_PORT="${QWEN3_PORT:-8090}"
VTON_PORT="${VTON_PORT:-8081}"
WHISPER_PORT="${WHISPER_PORT:-8765}"
WHISPER_WAV="${WHISPER_WAV:-}"
ONLY=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qwen3-port) QWEN3_PORT="$2"; shift 2 ;;
    --vton-port) VTON_PORT="$2"; shift 2 ;;
    --whisper-port) WHISPER_PORT="$2"; shift 2 ;;
    --whisper-wav) WHISPER_WAV="$2"; shift 2 ;;
    --only) ONLY+=("$2"); shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage: test_all.sh [options]
  --qwen3-port PORT
  --vton-port PORT
  --whisper-port PORT
  --whisper-wav PATH      日本語 wav (16kHz mono int16) を指定すると Whisper で日本語認識まで判定
  --only {qwen3|vton|whisper}  指定モデルのみ実行 (複数指定可)
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
MODELS_ROOT="$(cd "$ROOT/../models" && pwd)"

# モデル名 -> ディレクトリのマッピング
model_dir() {
  case "$1" in
    qwen3)   echo "$MODELS_ROOT/qwen3-vl" ;;
    vton)    echo "$MODELS_ROOT/qwen-image-edit" ;;
    whisper) echo "$MODELS_ROOT/whisper" ;;
    *) echo ""; return 1 ;;
  esac
}

run_one() {
  local name="$1"
  shift
  if (( ${#ONLY[@]} > 0 )); then
    local hit=0
    for o in "${ONLY[@]}"; do [[ "$o" == "$name" ]] && hit=1; done
    [[ "$hit" == "0" ]] && { echo "[$name] skipped (--only filter)"; return 99; }
  fi
  local dir
  dir="$(model_dir "$name")" || { echo "[$name] unknown model"; return 2; }
  echo "==============================="
  echo "[$name] starting ($dir/test.sh)"
  echo "==============================="
  bash "$dir/test.sh" "$@"
  return $?
}

declare -A RESULT
run_one qwen3 --port "$QWEN3_PORT"; RESULT[qwen3]=$?
echo
run_one vton --port "$VTON_PORT"; RESULT[vton]=$?
echo
if [[ -n "$WHISPER_WAV" ]]; then
  run_one whisper --port "$WHISPER_PORT" --wav "$WHISPER_WAV"; RESULT[whisper]=$?
else
  run_one whisper --port "$WHISPER_PORT"; RESULT[whisper]=$?
fi

echo
echo "================ SUMMARY ================"
overall=0
for k in qwen3 vton whisper; do
  c="${RESULT[$k]:-?}"
  case "$c" in
    0) printf '  %-8s : PASS\n' "$k" ;;
    99) printf '  %-8s : SKIP\n' "$k" ;;
    *) printf '  %-8s : FAIL (rc=%s)\n' "$k" "$c"; overall=1 ;;
  esac
done

exit "$overall"
