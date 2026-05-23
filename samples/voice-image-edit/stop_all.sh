#!/usr/bin/env bash
# 3 モデル一撃停止。pid ファイル → プロセス検索の順でフォールバック。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
MODELS_ROOT="$(cd "$ROOT/../models" && pwd)"

# モデル名 -> pid ファイルのパス。各モデルの start.sh は <models>/<name>/logs/<short>.pid に書く。
pidfile_for() {
  case "$1" in
    qwen3)   echo "$MODELS_ROOT/qwen3-vl/logs/qwen3.pid" ;;
    vton)    echo "$MODELS_ROOT/qwen-image-edit/logs/vton.pid" ;;
    whisper) echo "$MODELS_ROOT/whisper/logs/whisper.pid" ;;
    *) echo ""; return 1 ;;
  esac
}

stop_one() {
  local name="$1"
  local pattern="$2"
  local pidfile
  pidfile="$(pidfile_for "$name")" || return 0

  if [[ -f "$pidfile" ]]; then
    local pid
    pid=$(cat "$pidfile" 2>/dev/null || echo "")
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      echo "[stop] $name pid=$pid (pidfile)"
      kill "$pid" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi

  # Fallback: pattern 検索で取りこぼしを停止
  local pids
  pids=$(pgrep -f "$pattern" || true)
  if [[ -n "$pids" ]]; then
    echo "[stop] $name pids=$pids (pattern)"
    # shellcheck disable=SC2086
    kill $pids 2>/dev/null || true
    sleep 2
    pids=$(pgrep -f "$pattern" || true)
    if [[ -n "$pids" ]]; then
      # shellcheck disable=SC2086
      kill -9 $pids 2>/dev/null || true
    fi
  fi
}

stop_one qwen3   "vllm serve.*Qwen3-VL"
stop_one vton    "python serve.py.*compiled_models"
stop_one whisper "whisper_server.py"

echo "[stop_all] done"
