#!/usr/bin/env bash
# Whisper-large-v3 個別起動 (Neuron, NeuronCore 48 単独)
# WHISPER_LANGUAGE=ja|en|auto で認識言語を切替。
# 既に同ポートで起動中の場合はスキップ。
set -euo pipefail

PORT="${PORT:-8765}"
PATH_PREFIX="${PATH_PREFIX:-/whisper-neuron}"
MODEL_DIR="${MODEL_DIR:-/models/whisper-large-v3-neuron}"
MODEL_ID="${MODEL_ID:-openai/whisper-large-v3}"
NEURON_CORE="${NEURON_CORE:-48}"
LANGUAGE="${WHISPER_LANGUAGE:-ja}"
VENV="${VENV:-/opt/aws_neuronx_venv_pytorch_2_9_nxd_inference}"
SERVER_PY="${SERVER_PY:-${PWD}/whisper_server.py}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --path-prefix) PATH_PREFIX="$2"; shift 2 ;;
    --model-dir) MODEL_DIR="$2"; shift 2 ;;
    --model-id) MODEL_ID="$2"; shift 2 ;;
    --core) NEURON_CORE="$2"; shift 2 ;;
    --language) LANGUAGE="$2"; shift 2 ;;
    --venv) VENV="$2"; shift 2 ;;
    --server-py) SERVER_PY="$2"; shift 2 ;;
    *) echo "[whisper] Unknown arg: $1"; exit 1 ;;
  esac
done

LOG_DIR="${LOG_DIR:-$(cd "$(dirname "$0")" && pwd)/logs}"
mkdir -p "$LOG_DIR"
LOG="$LOG_DIR/whisper.log"
PIDFILE="$LOG_DIR/whisper.pid"

if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${PORT}\$"; then
  echo "[whisper] port ${PORT} already listening — skip start"
  exit 0
fi

if [[ ! -f "$SERVER_PY" ]]; then
  echo "[whisper] ERROR: whisper_server.py not found at $SERVER_PY"
  exit 1
fi

# whisper_server.py の language="en" ハードコードを env 経由で切替できるよう一回だけパッチ。
# 既にパッチ済みなら何もしない。
if ! grep -q "WHISPER_LANGUAGE_ENV_PATCH" "$SERVER_PY"; then
  python3 - <<PYEOF "$SERVER_PY"
import io, re, sys
p = sys.argv[1]
src = io.open(p, encoding="utf-8").read()
# Insert language env read near top imports if absent
if "WHISPER_LANGUAGE_ENV_PATCH" not in src:
    marker = "PORT = int(os.environ.get(\"PORT\""
    inject = (
        "# WHISPER_LANGUAGE_ENV_PATCH: ja/en/auto 切替対応\n"
        "_LANG_ENV = os.environ.get(\"WHISPER_LANGUAGE\", \"ja\").strip().lower()\n"
        "WHISPER_LANGUAGE = None if _LANG_ENV in (\"\", \"auto\", \"none\") else _LANG_ENV\n"
    )
    src = src.replace(marker, inject + marker, 1)
    # Replace generate(... language=\"en\") call sites with WHISPER_LANGUAGE
    src = re.sub(r'language\s*=\s*"en"', 'language=WHISPER_LANGUAGE', src)
    io.open(p, "w", encoding="utf-8").write(src)
    print("[whisper] patched WHISPER_LANGUAGE support into:", p)
else:
    print("[whisper] already patched")
PYEOF
fi

cd "$(dirname "$SERVER_PY")"

# shellcheck disable=SC1091
source "${VENV}/bin/activate"

export NEURON_RT_VISIBLE_CORES="$NEURON_CORE"
export NEURON_RT_NUM_CORES=1
export PORT="$PORT"
export PATH_PREFIX="$PATH_PREFIX"
export MODEL_DIR="$MODEL_DIR"
export MODEL_ID="$MODEL_ID"
export WHISPER_LANGUAGE="$LANGUAGE"

echo "[whisper] launching on :${PORT} (core=${NEURON_CORE}, language=${LANGUAGE})"
nohup python whisper_server.py >>"$LOG" 2>&1 &
echo $! > "$PIDFILE"
echo "[whisper] pid=$(cat "$PIDFILE") log=$LOG"
