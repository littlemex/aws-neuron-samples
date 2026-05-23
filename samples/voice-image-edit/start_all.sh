#!/usr/bin/env bash
# 3 モデル一撃起動。各モデルのポートは個別に指定可能。
# 既に同ポートで起動中のサーバーはそのまま (skip) する。
set -euo pipefail

QWEN3_PORT="${QWEN3_PORT:-8090}"
VTON_PORT="${VTON_PORT:-8081}"
WHISPER_PORT="${WHISPER_PORT:-8765}"
WHISPER_LANGUAGE="${WHISPER_LANGUAGE:-ja}"
SKIP=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qwen3-port) QWEN3_PORT="$2"; shift 2 ;;
    --vton-port) VTON_PORT="$2"; shift 2 ;;
    --whisper-port) WHISPER_PORT="$2"; shift 2 ;;
    --whisper-language) WHISPER_LANGUAGE="$2"; shift 2 ;;
    --skip) SKIP+=("$2"); shift 2 ;;
    -h|--help)
      cat <<'EOF'
Usage: start_all.sh [options]
  --qwen3-port PORT          (default 8090)
  --vton-port PORT           (default 8081)
  --whisper-port PORT        (default 8765)
  --whisper-language LANG    (ja | en | auto, default ja)
  --skip {qwen3|vton|whisper}  指定モデルの起動をスキップ (複数指定可)
EOF
      exit 0
      ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

ROOT="$(cd "$(dirname "$0")" && pwd)"
MODELS_ROOT="$(cd "$ROOT/../models" && pwd)"

is_skipped() {
  local n="$1"
  for s in "${SKIP[@]:-}"; do [[ "$s" == "$n" ]] && return 0; done
  return 1
}

if ! is_skipped qwen3; then
  bash "$MODELS_ROOT/qwen3-vl/start.sh" --port "$QWEN3_PORT"
fi
if ! is_skipped vton; then
  bash "$MODELS_ROOT/qwen-image-edit/start.sh" --port "$VTON_PORT"
fi
if ! is_skipped whisper; then
  WHISPER_LANGUAGE="$WHISPER_LANGUAGE" \
    bash "$MODELS_ROOT/whisper/start.sh" --port "$WHISPER_PORT" --language "$WHISPER_LANGUAGE"
fi

echo
echo "[start_all] launched. status:"
bash "$ROOT/status.sh" || true
