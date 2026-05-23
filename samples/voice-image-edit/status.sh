#!/usr/bin/env bash
# 3 モデルの稼働状態を一覧表示
set -uo pipefail

QWEN3_PORT="${QWEN3_PORT:-8090}"
VTON_PORT="${VTON_PORT:-8081}"
WHISPER_PORT="${WHISPER_PORT:-8765}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --qwen3-port) QWEN3_PORT="$2"; shift 2 ;;
    --vton-port) VTON_PORT="$2"; shift 2 ;;
    --whisper-port) WHISPER_PORT="$2"; shift 2 ;;
    *) shift ;;
  esac
done

probe() {
  local name="$1" port="$2" path="$3"
  local code
  code=$(curl -sS -m 5 -o /dev/null -w '%{http_code}' "http://localhost:${port}${path}" 2>/dev/null || echo "ERR")
  printf '  %-8s :%-5s %-22s -> %s\n' "$name" "$port" "$path" "$code"
}

echo "[status] listening ports:"
ss -tln 2>/dev/null | awk -v p1="$QWEN3_PORT" -v p2="$VTON_PORT" -v p3="$WHISPER_PORT" \
  '$4 ~ ":"p1"$" || $4 ~ ":"p2"$" || $4 ~ ":"p3"$" {print "  "$4}'

echo "[status] processes:"
ps -eo pid,user,comm,args 2>/dev/null \
  | grep -E "vllm serve|serve.py|whisper_server" \
  | grep -v grep \
  | awk '{print "  pid="$1" user="$2" cmd="$3}'

echo "[status] /health probes:"
probe qwen3   "$QWEN3_PORT"   "/health"
probe vton    "$VTON_PORT"    "/health"
probe whisper "$WHISPER_PORT" "/whisper-neuron/health"
