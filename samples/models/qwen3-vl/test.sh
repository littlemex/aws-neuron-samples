#!/usr/bin/env bash
# Qwen3-VL-8B-Thinking 動作確認 (日本語応答 + 画像理解)
# - 1) 日本語チャット: 「自己紹介してください」→ 日本語文字を含むかを判定
# - 2) 画像理解 + 日本語: ローカル合成した PNG (赤背景に黄色い円) を data:image/png;base64,... で渡す
#
# OK 条件:
#   両方の応答に日本語 (ひらがな/カタカナ/漢字) が含まれていること
set -uo pipefail

PORT="${PORT:-8090}"
MODEL="${MODEL:-/models/Qwen3-VL-8B-Thinking}"
TIMEOUT="${TIMEOUT:-300}"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --model) MODEL="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

URL="http://localhost:${PORT}/v1/chat/completions"

contains_japanese_file() {
  python3 - "$1" <<'PYEOF'
import sys, re, pathlib
text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore")
print("YES" if re.search(r'[぀-ゟ゠-ヿ一-鿿]', text) else "NO")
PYEOF
}

extract_text() {
  python3 - "$1" <<'PYEOF'
import json,sys,pathlib
try:
    d=json.loads(pathlib.Path(sys.argv[1]).read_text())
except Exception as e:
    print(f"<json parse error: {e}>"); sys.exit(0)
if "error" in d:
    print(f"<server error: {json.dumps(d['error'])[:600]}>"); sys.exit(0)
ch=(d.get("choices") or [{}])[0]
msg=ch.get("message") or {}
print((msg.get("reasoning_content") or "")+"\n"+(msg.get("content") or ""))
PYEOF
}

# 64x64 の PNG (赤背景に黄色い丸) を Python stdlib (zlib + png chunks) で生成し base64 化
DATAURL=$(python3 - <<'PYEOF'
import base64, struct, zlib
W=H=64
pixels=bytearray()
cx,cy,r=W//2,H//2,18
for y in range(H):
    pixels.append(0)  # filter byte for each row
    for x in range(W):
        if (x-cx)**2+(y-cy)**2 <= r*r:
            pixels += bytes([255,220,0])    # yellow
        else:
            pixels += bytes([200,30,30])    # red
def chunk(t,d):
    return struct.pack(">I",len(d))+t+d+struct.pack(">I", zlib.crc32(t+d)&0xffffffff)
sig=b'\x89PNG\r\n\x1a\n'
ihdr=struct.pack(">IIBBBBB",W,H,8,2,0,0,0)
idat=zlib.compress(bytes(pixels),9)
png=sig+chunk(b'IHDR',ihdr)+chunk(b'IDAT',idat)+chunk(b'IEND',b'')
print("data:image/png;base64,"+base64.b64encode(png).decode())
PYEOF
)

pass=0; fail=0

echo "=== [qwen3] 1/2 日本語チャット ==="
REQ1='{
  "model": "'"$MODEL"'",
  "messages": [
    {"role": "system", "content": "あなたは親切なアシスタントです。必ず日本語で回答してください。"},
    {"role": "user", "content": "あなたは何ができますか？2-3文で簡潔に教えてください。"}
  ],
  "max_tokens": 256,
  "temperature": 0.2
}'
RESP1="$TMP/resp1.json"
HTTP1=$(curl -sS -m "$TIMEOUT" -o "$RESP1" -w '%{http_code}' \
  -H 'Content-Type: application/json' -X POST "$URL" -d "$REQ1" || echo "ERR")

echo "[qwen3] HTTP=$HTTP1"
echo "[qwen3] response (head):"
extract_text "$RESP1" | head -c 600; echo
if [[ "$HTTP1" == "200" && "$(contains_japanese_file "$RESP1")" == "YES" ]]; then
  echo "[qwen3] japanese-detected: PASS"
  pass=$((pass+1))
else
  echo "[qwen3] japanese-detected: FAIL"
  fail=$((fail+1))
fi

echo
echo "=== [qwen3] 2/2 画像 + 日本語 ==="
REQ2_FILE="$TMP/req2.json"
python3 - "$REQ2_FILE" "$MODEL" "$DATAURL" <<'PYEOF'
import json,sys
out_path, model, image_url = sys.argv[1], sys.argv[2], sys.argv[3]
body = {
  "model": model,
  "messages": [
    {"role": "user", "content": [
      {"type": "image_url", "image_url": {"url": image_url}},
      {"type": "text", "text": "この画像に何が写っていますか？日本語で1-2文で簡潔に答えてください。"}
    ]}
  ],
  "max_tokens": 256,
  "temperature": 0.2
}
open(out_path,"w").write(json.dumps(body))
PYEOF

RESP2="$TMP/resp2.json"
HTTP2=$(curl -sS -m "$TIMEOUT" -o "$RESP2" -w '%{http_code}' \
  -H 'Content-Type: application/json' -X POST "$URL" --data-binary "@$REQ2_FILE" || echo "ERR")

echo "[qwen3] HTTP=$HTTP2"
echo "[qwen3] response (head):"
extract_text "$RESP2" | head -c 600; echo
if [[ "$HTTP2" == "200" && "$(contains_japanese_file "$RESP2")" == "YES" ]]; then
  echo "[qwen3] image+japanese: PASS"
  pass=$((pass+1))
else
  echo "[qwen3] image+japanese: FAIL"
  fail=$((fail+1))
fi

echo
echo "[qwen3] result: pass=${pass} fail=${fail}"
[[ "$fail" -eq 0 ]] && exit 0 || exit 1
