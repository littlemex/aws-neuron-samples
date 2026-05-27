#!/usr/bin/env bash
# Qwen-Image-Edit 個別起動 (TP=8, NeuronCore 16-23)
# 既に同ポートで起動中の場合はスキップ。
set -euo pipefail

PORT="${PORT:-8081}"
HOST="${HOST:-0.0.0.0}"
COMPILED_DIR="${COMPILED_DIR:-/opt/dlami/nvme/compiled_models}"
HEIGHT="${HEIGHT:-1024}"
WIDTH="${WIDTH:-1024}"
PATCH_MULT="${PATCH_MULT:-3}"
NEURON_CORES="${NEURON_CORES:-16-23}"
WORLD_SIZE="${WORLD_SIZE:-8}"
SERVE_PY="${SERVE_PY:-${PWD}/serve.py}"
VENV="${VENV:-/opt/aws_neuronx_venv_pytorch_2_9_nxd_inference}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --compiled-dir) COMPILED_DIR="$2"; shift 2 ;;
    --height) HEIGHT="$2"; shift 2 ;;
    --width) WIDTH="$2"; shift 2 ;;
    --cores) NEURON_CORES="$2"; shift 2 ;;
    --world-size) WORLD_SIZE="$2"; shift 2 ;;
    --serve-py) SERVE_PY="$2"; shift 2 ;;
    --venv) VENV="$2"; shift 2 ;;
    *) echo "[vton] Unknown arg: $1"; exit 1 ;;
  esac
done

if [[ ! -x "${VENV}/bin/python" ]]; then
  echo "[vton] ERROR: venv python not found at ${VENV}/bin/python"
  exit 1
fi
# shellcheck disable=SC1091
source "${VENV}/bin/activate"

LOG_DIR="${LOG_DIR:-$(cd "$(dirname "$0")" && pwd)/logs}"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/vton.log"
PIDFILE="$LOG_DIR/vton.pid"

if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
  echo "[vton] port ${PORT} already listening — skip start"
  exit 0
fi

if [[ ! -f "$SERVE_PY" ]]; then
  echo "[vton] ERROR: serve.py not found at $SERVE_PY"
  exit 1
fi

cd "$(dirname "$SERVE_PY")"

export NEURON_RT_VISIBLE_CORES="$NEURON_CORES"
export NEURON_RT_NUM_CORES="$WORLD_SIZE"

echo "[vton] launching serve.py on :${PORT} (TP=${WORLD_SIZE}, cores=${NEURON_CORES}) (log -> ${LOG})"
# When run under systemd Type=simple, do NOT background — the main process must
# stay in the foreground so systemd tracks the actual python process. Tee to log
# file for ad-hoc debugging.
if [[ -t 1 ]]; then
  # Interactive shell: keep legacy nohup behaviour for manual launches.
  nohup python serve.py \
    --host "$HOST" --port "$PORT" \
    --compiled_models_dir "$COMPILED_DIR" \
    --height "$HEIGHT" --width "$WIDTH" \
    --patch_multiplier "$PATCH_MULT" \
    --use_v3_cfg \
    >>"$LOG" 2>&1 &
  echo $! > "$PIDFILE"
  echo "[vton] pid=$(cat "$PIDFILE") log=$LOG"
else
  # Non-interactive (systemd / SSM): exec into python so it becomes the main PID.
  echo $$ > "$PIDFILE"
  exec python serve.py \
    --host "$HOST" --port "$PORT" \
    --compiled_models_dir "$COMPILED_DIR" \
    --height "$HEIGHT" --width "$WIDTH" \
    --patch_multiplier "$PATCH_MULT" \
    --use_v3_cfg
fi
