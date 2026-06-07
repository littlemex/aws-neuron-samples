#!/usr/bin/env bash
# XTTSv2 server launcher (DLC, NxD Inference SDK 2.28).
#
# This wraps `docker run` against an image built from Dockerfile.server
# (=DLC + coqui-tts + torchaudio + fastapi). Production usage is via the
# systemd unit installed by tasks/xttsv2-server.json; this script exists
# for ad-hoc local launches.
#
# Default core window = 0-3 on trn2.3xlarge (TP=4, LNC=2). On the
# trn2.48xlarge demo the assignment is cores 56-59 to stay clear of
# Whisper (48-55) / Qwen3-VL (32-47) / Qwen-Image-Edit (0-31).
# A second instance on the same port is a no-op (port-in-use guard).

set -euo pipefail

PORT="${PORT:-8770}"
HOST="${HOST:-127.0.0.1}"
COMPILED_DIR="${COMPILED_MODEL_PATH:-/models/xttsv2-neuron-nxd}"
MODEL_DIR="${XTTS_MODEL_DIR:-/models/XTTS-v2}"
VOICES_DIR="${XTTSV2_VOICES_DIR:-/models/xttsv2-voices}"
DEFAULT_VOICE="${XTTSV2_DEFAULT_VOICE:-default}"
LANGUAGE="${XTTSV2_LANGUAGE:-ja}"
TP_DEGREE="${TP_DEGREE:-4}"
NEURON_CORES="${NEURON_CORES:-0-3}"
RUNTIME_IMAGE="${RUNTIME_IMAGE:-xttsv2-server:sdk2.28.0-ja}"
APP_DIR="${APP_DIR:-$(cd "$(dirname "$0")" && pwd)}"
CONTAINER_NAME="${CONTAINER_NAME:-xttsv2-server}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --host) HOST="$2"; shift 2 ;;
    --compiled-dir) COMPILED_DIR="$2"; shift 2 ;;
    --model-dir) MODEL_DIR="$2"; shift 2 ;;
    --voices-dir) VOICES_DIR="$2"; shift 2 ;;
    --default-voice) DEFAULT_VOICE="$2"; shift 2 ;;
    --language) LANGUAGE="$2"; shift 2 ;;
    --tp-degree) TP_DEGREE="$2"; shift 2 ;;
    --cores) NEURON_CORES="$2"; shift 2 ;;
    --image) RUNTIME_IMAGE="$2"; shift 2 ;;
    --app-dir) APP_DIR="$2"; shift 2 ;;
    --name) CONTAINER_NAME="$2"; shift 2 ;;
    *) echo "[xttsv2] unknown arg: $1"; exit 1 ;;
  esac
done

if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
  echo "[xttsv2] port ${PORT} already listening — skip start"
  exit 0
fi

if [[ ! -f "$APP_DIR/xttsv2_server.py" ]]; then
  echo "[xttsv2] ERROR: xttsv2_server.py not found at $APP_DIR/xttsv2_server.py"
  exit 1
fi
if [[ ! -d "$COMPILED_DIR" ]] || [[ ! -f "$COMPILED_DIR/.compile_metadata.json" ]]; then
  echo "[xttsv2] ERROR: compiled model not found at $COMPILED_DIR"
  echo "[xttsv2]   run xttsv2-precompile.json first, then retry."
  exit 1
fi
if [[ ! -f "$MODEL_DIR/model.pth" ]]; then
  echo "[xttsv2] ERROR: XTTSv2 checkpoint not found at $MODEL_DIR/model.pth"
  exit 1
fi
if ! docker image inspect "$RUNTIME_IMAGE" >/dev/null 2>&1; then
  echo "[xttsv2] ERROR: runtime image $RUNTIME_IMAGE not built. Run: docker build -t $RUNTIME_IMAGE -f $APP_DIR/Dockerfile.server $APP_DIR"
  exit 1
fi

# Clean stale containers from a previous crash.
docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true

echo "[xttsv2] launching $RUNTIME_IMAGE on :${PORT} (cores=${NEURON_CORES}, TP=${TP_DEGREE})"

docker_args=(
  --rm
  --name "$CONTAINER_NAME"
  --device /dev/neuron0
  --shm-size 8g
  -p "${HOST}:${PORT}:${PORT}"
  -e "PORT=$PORT"
  -e PYTHONUNBUFFERED=1
  -e "NEURON_RT_VISIBLE_CORES=$NEURON_CORES"
  -e "NEURON_RT_NUM_CORES=$TP_DEGREE"
  -e NEURON_RT_VIRTUAL_CORE_SIZE=2
  -e NEURON_LOGICAL_NC_CONFIG=2
  -e "COMPILED_MODEL_PATH=$COMPILED_DIR"
  -e "XTTS_MODEL_DIR=$MODEL_DIR"
  -e "XTTSV2_VOICES_DIR=$VOICES_DIR"
  -e "XTTSV2_DEFAULT_VOICE=$DEFAULT_VOICE"
  -e "XTTSV2_LANGUAGE=$LANGUAGE"
  -e "TP_DEGREE=$TP_DEGREE"
  -v /models:/models
  -v "$APP_DIR:/app:ro"
  -w /app
  --entrypoint /bin/bash
  "$RUNTIME_IMAGE"
  -lc 'exec uvicorn xttsv2_server:app --host 0.0.0.0 --port "$PORT" --proxy-headers --no-server-header --timeout-keep-alive 75'
)

if [[ -t 1 ]]; then
  exec docker run "${docker_args[@]}"
else
  exec docker run "${docker_args[@]}"
fi
