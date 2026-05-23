#!/usr/bin/env bash
# Qwen-Image-Edit 動作確認 (日本語プロンプトで画像編集)
#
# - 入力画像をローカル合成 (Python stdlib zlib+PNG, 256x256 単色) → multipart で /infer に POST
# - prompt は日本語: 「画像全体を朝焼けの空のように暖色のオレンジに変えてください」
# - OK 条件: HTTP 200 で PNG が返る (PNG マジックバイト確認) かつ X-Inference-Time が記録される
set -uo pipefail

PORT="${PORT:-8081}"
TIMEOUT="${TIMEOUT:-900}"
PROMPT="${PROMPT:-画像全体を朝焼けの空のように暖色のオレンジに変えてください。}"
NEG_PROMPT="${NEG_PROMPT:-ぼやけた、低品質、歪んだ}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --prompt) PROMPT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

INPUT="$TMP/input.png"
OUT="$TMP/out.png"

# 256x256 単色 PNG を Python stdlib (zlib + PNG chunks) で合成 (PIL 不要)
python3 - "$INPUT" <<'PYEOF'
import struct, zlib, sys
out=sys.argv[1]
W=H=256
pixels=bytearray()
for y in range(H):
    pixels.append(0)  # filter
    for x in range(W):
        pixels += bytes([40,160,70])  # green
def chunk(t,d):
    return struct.pack(">I",len(d))+t+d+struct.pack(">I", zlib.crc32(t+d)&0xffffffff)
sig=b'\x89PNG\r\n\x1a\n'
ihdr=struct.pack(">IIBBBBB",W,H,8,2,0,0,0)
idat=zlib.compress(bytes(pixels),9)
png=sig+chunk(b'IHDR',ihdr)+chunk(b'IDAT',idat)+chunk(b'IEND',b'')
open(out,"wb").write(png)
PYEOF

URL="http://localhost:${PORT}/infer"
echo "=== [vton] 日本語プロンプト image edit -> ${URL} ==="
echo "[vton] prompt: ${PROMPT}"

HTTP=$(curl -sS -m "$TIMEOUT" -o "$OUT" -D "$TMP/headers.txt" -w '%{http_code}' \
  -X POST "$URL" \
  -F "image1=@${INPUT};type=image/png" \
  -F "prompt=${PROMPT}" \
  -F "negative_prompt=${NEG_PROMPT}" \
  -F "num_inference_steps=20" \
  -F "true_cfg_scale=3.0" \
  -F "seed=42" || echo "ERR")

echo "[vton] HTTP=${HTTP}"

if [[ "$HTTP" != "200" ]]; then
  echo "[vton] FAIL: non-200"
  head -c 1000 "$OUT" 2>/dev/null; echo
  exit 1
fi

SIZE=$(stat -c%s "$OUT" 2>/dev/null || stat -f%z "$OUT")
INF_TIME=$(awk -F': *' 'tolower($1)=="x-inference-time"{gsub("\r","",$2); print $2}' "$TMP/headers.txt")
MAGIC=$(head -c 8 "$OUT" | od -An -tx1 | tr -d ' ')

echo "[vton] output size=${SIZE} bytes  inference-time=${INF_TIME}"
echo "[vton] magic bytes (first 8): ${MAGIC}"

if [[ "$MAGIC" =~ ^89504e470d0a1a0a ]]; then
  echo "[vton] PASS: valid PNG returned (Japanese prompt accepted)"
  exit 0
else
  echo "[vton] FAIL: returned bytes are not PNG"
  exit 1
fi
