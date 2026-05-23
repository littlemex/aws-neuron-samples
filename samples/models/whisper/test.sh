#!/usr/bin/env bash
# Whisper-large-v3 (Neuron) 動作確認
#
# 段階:
#   1) /health 200
#   2) /whisper-neuron/ws WebSocket 接続成立 + バイナリ送信応答 (1.5秒のサイン波 PCM int16)
#      → サーバが処理できることを確認 (text 中身は問わない)
#   3) (--wav 指定時のみ) 実日本語音声 wav を流し込み、戻り text に日本語文字が含まれるかを判定
#
# `websockets` パッケージが必要なため、システム python3 → Whisper venv python へ自動フォールバック。
set -uo pipefail

PORT="${PORT:-8765}"
PATH_PREFIX="${PATH_PREFIX:-/whisper-neuron}"
DEFAULT_WAV="$(cd "$(dirname "$0")" && pwd)/_assets/sample_ja.wav"
WAV="${WAV:-}"
TIMEOUT="${TIMEOUT:-90}"
[[ -z "$WAV" && -f "$DEFAULT_WAV" ]] && WAV="$DEFAULT_WAV"
WHISPER_VENV_PY="${WHISPER_VENV_PY:-/opt/aws_neuronx_venv_pytorch_2_9_nxd_inference/bin/python}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --path-prefix) PATH_PREFIX="$2"; shift 2 ;;
    --wav) WAV="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

URL_HEALTH="http://localhost:${PORT}${PATH_PREFIX}/health"
URL_WS="ws://localhost:${PORT}${PATH_PREFIX}/ws"

# websockets を持つ python を探す
pick_python() {
  for cand in python3 "$WHISPER_VENV_PY"; do
    "$cand" -c "import websockets" 2>/dev/null && { echo "$cand"; return; }
  done
  echo ""
}
PY="$(pick_python)"
echo "[whisper] python with websockets = ${PY:-<none>}"

pass=0; fail=0

echo "=== [whisper] 1/3 health ==="
HTTP=$(curl -sS -m 10 -o "$TMP/health.json" -w '%{http_code}' "$URL_HEALTH" || echo ERR)
echo "[whisper] HTTP=$HTTP body=$(head -c 200 "$TMP/health.json" 2>/dev/null)"
if [[ "$HTTP" == "200" ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi

echo
echo "=== [whisper] 2/3 WebSocket synthetic PCM ==="
if [[ -z "$PY" ]]; then
  echo "[whisper] websockets package missing in any python — SKIP ws test"
else
  "$PY" - "$URL_WS" "$TIMEOUT" <<'PYEOF'
import asyncio, json, sys, math, array
URL = sys.argv[1]
TIMEOUT = int(sys.argv[2])
import websockets

def make_pcm():
    buf = array.array("h")
    sr=16000
    for i in range(int(1.5*sr)):
        buf.append(int(0.3*32767*math.sin(2*math.pi*440*(i/sr))))
    return buf.tobytes()

async def main():
    pcm=make_pcm()
    chunk=16000*2
    got=[]
    async with websockets.connect(URL, max_size=None) as ws:
        for i in range(0,len(pcm),chunk):
            await ws.send(pcm[i:i+chunk])
            await asyncio.sleep(0.1)
        try:
            for _ in range(3):
                m=await asyncio.wait_for(ws.recv(), timeout=10)
                got.append(m)
        except asyncio.TimeoutError:
            pass
    print("[whisper] ws messages received:", len(got))
    for g in got[:3]:
        print("  ->", str(g)[:200])

asyncio.run(main())
PYEOF
  rc=$?
  if [[ "$rc" == "0" ]]; then
    echo "[whisper] ws PASS"
    pass=$((pass+1))
  else
    echo "[whisper] ws FAIL rc=$rc"
    fail=$((fail+1))
  fi
fi

echo
echo "=== [whisper] 3/3 Japanese audio (optional) ==="
if [[ -z "$WAV" ]]; then
  echo "[whisper] no --wav supplied — skip Japanese audio recognition test"
  echo "[whisper]   pass --wav /path/to/16kHz_mono_int16.wav to verify Japanese text output"
else
  if [[ ! -f "$WAV" ]]; then
    echo "[whisper] FAIL: wav not found: $WAV"
    fail=$((fail+1))
  elif [[ -z "$PY" ]]; then
    echo "[whisper] FAIL: no python with websockets available"
    fail=$((fail+1))
  else
    "$PY" - "$URL_WS" "$WAV" "$TIMEOUT" <<'PYEOF'
import asyncio, sys, wave, re, json
URL, WAV, TIMEOUT = sys.argv[1], sys.argv[2], int(sys.argv[3])
import websockets

def load_pcm16k(path):
    with wave.open(path,"rb") as wf:
        sr=wf.getframerate(); ch=wf.getnchannels(); sw=wf.getsampwidth(); n=wf.getnframes()
        raw=wf.readframes(n)
    assert sr==16000, f"sr={sr}"
    assert ch==1, f"ch={ch}"
    assert sw==2, f"sw={sw}"
    return raw

async def main():
    pcm=load_pcm16k(WAV)
    chunk=16000*2
    got=[]
    async with websockets.connect(URL, max_size=None) as ws:
        for i in range(0,len(pcm),chunk):
            await ws.send(pcm[i:i+chunk])
            await asyncio.sleep(0.1)
            try:
                m=await asyncio.wait_for(ws.recv(), timeout=2)
                got.append(m)
            except asyncio.TimeoutError:
                pass
        try:
            for _ in range(3):
                m=await asyncio.wait_for(ws.recv(), timeout=TIMEOUT)
                got.append(m)
        except asyncio.TimeoutError:
            pass
    # サーバは JSON 文字列で返してくることがある (unicode escape されている可能性あり)。
    # text フィールドだけ取り出して decode し、結合する。
    decoded = []
    for g in got:
        s = g.decode("utf-8") if isinstance(g, (bytes, bytearray)) else str(g)
        try:
            obj = json.loads(s)
            decoded.append(obj.get("text") or "")
        except Exception:
            # raw string fallback (unicode escape を Python 文字列としてデコード)
            try:
                decoded.append(s.encode("utf-8").decode("unicode_escape"))
            except Exception:
                decoded.append(s)
    text = " ".join(decoded)
    print("[whisper] transcripts (decoded head):", text[:400])
    if re.search(r"[぀-ゟ゠-ヿ一-鿿]", text):
        print("[whisper] japanese-detected: PASS"); sys.exit(0)
    print("[whisper] japanese-detected: FAIL"); sys.exit(1)

asyncio.run(main())
PYEOF
    rc=$?
    if [[ "$rc" == "0" ]]; then pass=$((pass+1)); else fail=$((fail+1)); fi
  fi
fi

echo
echo "[whisper] result: pass=${pass} fail=${fail}"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
