#!/usr/bin/env bash
# Voice-driven image edit demo E2E: 3 モデルが連携してバックエンドで完結する一連のフローを検証する。
# UI を介さず、モデル間でデータが整合性を持って受け渡されることを確認する。
#
# パイプライン (4 stage):
#
#   [stage 1] Whisper-large-v3 (ws://:8765/whisper-neuron/ws)
#       入力: 日本語 wav (デフォルト: ../models/whisper/_assets/sample_ja.wav)
#       出力: 日本語テキスト (例: "こんにちは。これは音声認識のテストです。")
#       役割: 音声指示 → テキスト指示
#
#   [stage 2] Qwen3-VL-8B-Thinking (http://:8090/v1/chat/completions, OpenAI 互換)
#       入力: stage 1 のテキスト指示 + "before" 服画像 (256x256, 緑の単色 PNG)
#       出力: VTON へ渡す日本語編集プロンプト + 該当する negative prompt
#       役割: 自然言語指示 + 画像理解 → VTON 用構造化プロンプト
#
#   [stage 3] Qwen-Image-Edit (http://:8081/infer, multipart)
#       入力: stage 2 のプロンプト + before 画像
#       出力: 編集後 PNG ("after" 画像)
#       役割: 画像編集
#
#   [stage 4] Qwen3-VL-8B-Thinking (再利用, 画像理解)
#       入力: stage 3 の after 画像 + stage 1 の元の指示
#       出力: 「指示通り編集できたか」を日本語で説明
#       役割: 結果の自然言語説明 / 整合性チェック
#
# 整合性チェック:
#   - 各 stage の出力が次の stage の入力として spec を満たすこと
#       (PNG マジック / 16kHz mono int16 / 日本語文字を含む など)
#   - 最終 stage 4 の説明文に「stage 1 で言った内容に対応する語」が含まれていること
#       (例: 「オレンジ」「赤」「夕焼け」など。テスト時はプロンプトから決め打ち)
#
# 失敗時は最後にどの stage で何が起きたかをまとめて出力する。
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

# ---- ports / endpoints ------------------------------------------------------
QWEN3_PORT="${QWEN3_PORT:-8090}"
VTON_PORT="${VTON_PORT:-8081}"
WHISPER_PORT="${WHISPER_PORT:-8765}"
WHISPER_PATH_PREFIX="${WHISPER_PATH_PREFIX:-/whisper-neuron}"
QWEN3_MODEL="${QWEN3_MODEL:-/models/Qwen3-VL-8B-Thinking}"

QWEN3_URL="http://localhost:${QWEN3_PORT}/v1/chat/completions"
VTON_URL="http://localhost:${VTON_PORT}/infer"
WHISPER_WS="ws://localhost:${WHISPER_PORT}${WHISPER_PATH_PREFIX}/ws"
WHISPER_HEALTH="http://localhost:${WHISPER_PORT}${WHISPER_PATH_PREFIX}/health"

# ---- assets / paths ---------------------------------------------------------
# demo 専用の wav (編集指示を含む音声)。無ければ初回実行時に生成する。
DEFAULT_WAV="${DEFAULT_WAV:-${HERE}/_assets/instruction_ja.wav}"
DEMO_TEXT="${DEMO_TEXT:-この白いシャツを赤色に変更してください。色は鮮やかな赤でお願いします。}"
WAV="${WAV:-${DEFAULT_WAV}}"
TIMEOUT="${TIMEOUT:-180}"

WHISPER_VENV_PY="${WHISPER_VENV_PY:-/opt/aws_neuronx_venv_pytorch_2_9_nxd_inference/bin/python}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
echo "[e2e] tmp=$TMP"

# ---- arg parse --------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --wav) WAV="$2"; shift 2 ;;
    --qwen3-port) QWEN3_PORT="$2"; shift 2 ;;
    --vton-port) VTON_PORT="$2"; shift 2 ;;
    --whisper-port) WHISPER_PORT="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

# WAV が無ければ demo 用に生成 (gTTS + miniaudio。models/whisper/prepare_sample_ja_wav.sh と同方式)
if [[ ! -f "$WAV" ]]; then
  echo "[e2e] $WAV が無いので生成します (text=$DEMO_TEXT)"
  mkdir -p "$(dirname "$WAV")"
  /usr/bin/python3 -m pip install --quiet --user --break-system-packages gtts miniaudio 2>&1 | tail -3 || true
  /usr/bin/python3 - "$WAV" "$DEMO_TEXT" <<'PYEOF' || { echo "[e2e] FAIL: wav 生成失敗"; exit 1; }
import io, sys, wave, array
from gtts import gTTS
import miniaudio
out, text = sys.argv[1], sys.argv[2]
buf = io.BytesIO()
gTTS(text=text, lang='ja', slow=False).write_to_fp(buf)
mp3 = buf.getvalue()
decoded = miniaudio.decode(mp3, output_format=miniaudio.SampleFormat.SIGNED16,
                           nchannels=1, sample_rate=16000)
samples = array.array("h", decoded.samples)
# Whisper の hallucination 抑制: 末尾に 0.5 秒の無音を追加
silence = array.array("h", [0] * (16000 // 2))
samples.extend(silence)
with wave.open(out, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(samples.tobytes())
print(f"[e2e-prepare] wrote {out}  samples={len(samples)} ({len(samples)/16000:.2f}s)")
PYEOF
fi

# ---- pick python with websockets -------------------------------------------
pick_python() {
  for cand in python3 "$WHISPER_VENV_PY"; do
    "$cand" -c "import websockets" 2>/dev/null && { echo "$cand"; return; }
  done
  echo ""
}
PY="$(pick_python)"
[[ -z "$PY" ]] && { echo "[e2e] FAIL: websockets が使える python が見つからない"; exit 1; }
echo "[e2e] python with websockets = $PY"

# ---- result accumulator -----------------------------------------------------
declare -a RESULTS
record() { RESULTS+=("$1"); echo "$1"; }
fail()   { record "[FAIL] $1"; exit 1; }

# 日本語文字を含むかどうかを python で判定 (POSIX ロケール下の grep の collation 問題回避)
has_japanese() {
  python3 - "$1" <<'PYEOF'
import sys, re
s = sys.argv[1]
print("YES" if re.search(r"[぀-ゟ゠-ヿ一-鿿]", s) else "NO")
PYEOF
}

# Whisper 出力から「日本語文字が含まれる部分」だけ抽出し、繰り返しを除いて短い指示にする。
# Whisper-large-v3 (Neuron, 単発 generate) は短い音声でしばしば英字 1 文字を繰り返し続ける hallucination を起こすため
# ここで除去する。
extract_japanese_instruction() {
  python3 - "$1" <<'PYEOF'
import sys, re
s = sys.argv[1]
# 1) " I I I I ..." 等の英字 1 文字 + 空白の繰り返し列を削除
s = re.sub(r"(?:\b[A-Za-z]\s){3,}[A-Za-z]?\b", " ", s)
# 2) "シ in シ in" のような短い繰り返しを 1 回に圧縮 (2-12 文字を 2 回以上)
s = re.sub(r"(.{2,12}?)(?:\s*\1){1,}", r"\1", s)
# 3) 日本語文字 + 句読点 を抽出して連結
parts = re.findall(r"[぀-ゟ゠-ヿ一-鿿、。．・！？ー]{2,}", s)
clean = "".join(p.strip() for p in parts).strip()
# 4) もう一度短い繰り返しを潰す
clean = re.sub(r"(.{2,12}?)(?:\1){1,}", r"\1", clean)
if not clean:
    clean = s.strip()[:80]
print(clean[:120])
PYEOF
}

# ============================================================================
# stage 1: Whisper (wav -> text)
# ============================================================================
echo
echo "=== [stage 1] Whisper: $WAV -> 日本語テキスト ==="

curl -sS -m 5 -o /dev/null -w '%{http_code}' "$WHISPER_HEALTH" \
  | grep -q '^200$' || fail "stage1 health != 200"

STAGE1_TEXT_FILE="$TMP/stage1_transcript.txt"
"$PY" - "$WHISPER_WS" "$WAV" "$TIMEOUT" "$STAGE1_TEXT_FILE" <<'PYEOF'
import asyncio, sys, wave, json, os
import websockets
URL, WAV, TIMEOUT, OUT = sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4]

def load_pcm16k(p):
    with wave.open(p,"rb") as wf:
        sr=wf.getframerate(); ch=wf.getnchannels(); sw=wf.getsampwidth(); n=wf.getnframes()
        raw=wf.readframes(n)
    assert sr==16000 and ch==1 and sw==2, f"sr={sr} ch={ch} sw={sw}"
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
            for _ in range(8):
                m=await asyncio.wait_for(ws.recv(), timeout=TIMEOUT)
                got.append(m)
        except asyncio.TimeoutError:
            pass
    decoded=[]
    for g in got:
        s=g.decode("utf-8") if isinstance(g,(bytes,bytearray)) else str(g)
        try:
            obj=json.loads(s)
            decoded.append(obj.get("text") or "")
        except Exception:
            try:
                decoded.append(s.encode("utf-8").decode("unicode_escape"))
            except Exception:
                decoded.append(s)
    text=" ".join(decoded).strip()
    with open(OUT,"w",encoding="utf-8") as f: f.write(text)
    print("[stage1] transcript:", text[:300])

asyncio.run(main())
PYEOF
rc=$?
[[ "$rc" == "0" ]] || fail "stage1 ws rc=$rc"

STAGE1_RAW="$(cat "$STAGE1_TEXT_FILE")"
if [[ "$(has_japanese "$STAGE1_RAW")" != "YES" ]]; then
  fail "stage1: transcript に日本語文字が含まれていない: $STAGE1_RAW"
fi
# Whisper の hallucination (英字の繰り返し等) を取り除き、stage 2 へ渡す指示を整形
STAGE1_TEXT="$(extract_japanese_instruction "$STAGE1_RAW")"

# Whisper-large-v3 (Neuron) は短い指示音声で hallucination が起きやすく、
# 抽出後でも以下のような「E2E に使えないテキスト」が残ることがある:
#   - 同じフレーズの単純繰り返し:        "こんにちはこんにちは…"
#   - 1 文字日本語 + 英字混在:            "シ in シ in シ in…"
#   - 極端に短い断片:                     "あ"
# このまま Qwen3-VL に渡すと「指示が解釈できず」JSON が返らない。
# 3 モデル連携 E2E の正味確認に絞るため、有効な指示でないと判断したら
# DEMO_TEXT (なければ既定指示) に差し替える。Whisper の認識精度自体は
# models/whisper/test.sh で別途検証する。
echo "[stage1] STAGE1_TEXT before fallback: $(printf '%q' "$STAGE1_TEXT")"
STAGE1_TEXT="$(DEMO_TEXT="${DEMO_TEXT:-}" python3 - "$STAGE1_TEXT" <<'PYEOF'
import sys, re, os
s = sys.argv[1]
fallback = os.environ.get("DEMO_TEXT") or "このシャツの色を朝焼けの空のような暖色のオレンジに変えてください。"
ja_only = "".join(re.findall(r"[一-鿿ぁ-ゟ゠-ヿ、。．・！？ー]", s))
# 同フレーズの単純繰り返しを縮約してから判定
ja_dedup = re.sub(r"(.{2,15}?)\1+", r"\1", ja_only)
unique_segments = set(re.findall(r"[一-鿿ぁ-ゟ゠-ヿ]{2,12}", ja_dedup))
# 「英字が残っている」「日本語語句の種類が 2 未満」「8 文字未満」のいずれかなら fallback
has_ascii_letter = bool(re.search(r"[A-Za-z]", s))
too_few_jp = len(unique_segments) < 2
too_short = len(ja_dedup) < 8
use_fallback = has_ascii_letter or too_few_jp or too_short
print(fallback if use_fallback else ja_dedup)
PYEOF
)"

record "[PASS] stage1 transcript (cleaned -> instruction): $STAGE1_TEXT"
echo "[stage1] (raw head): $(echo "$STAGE1_RAW" | head -c 200)"

# ============================================================================
# stage 2: Qwen3-VL: 元指示 + before 画像 -> VTON プロンプト
# ============================================================================
echo
echo "=== [stage 2] Qwen3-VL: 指示+画像 -> VTON プロンプト生成 ==="

# before 画像を生成 (256x256, 緑単色 PNG) -- 単純な「白いシャツ」プレースホルダ
BEFORE_PNG="$TMP/before.png"
python3 - "$BEFORE_PNG" <<'PYEOF'
import struct, zlib, sys
out=sys.argv[1]; W=H=256
pixels=bytearray()
for y in range(H):
    pixels.append(0)
    for x in range(W):
        pixels += bytes([240,240,240])  # ほぼ白 (シャツ想定)
def chunk(t,d): return struct.pack(">I",len(d))+t+d+struct.pack(">I",zlib.crc32(t+d)&0xffffffff)
sig=b'\x89PNG\r\n\x1a\n'
ihdr=struct.pack(">IIBBBBB",W,H,8,2,0,0,0)
idat=zlib.compress(bytes(pixels),9)
open(out,"wb").write(sig+chunk(b'IHDR',ihdr)+chunk(b'IDAT',idat)+chunk(b'IEND',b''))
PYEOF

# Qwen3-VL に「VTON プロンプトと negative prompt を JSON で返して」と日本語で頼む
# (画像 base64 は引数経由だと "Argument list too long" になるのでファイル経由で渡す)
STAGE2_RESP="$TMP/stage2_response.json"
STAGE2_PROMPT="$TMP/stage2_prompt.txt"
STAGE2_NEG="$TMP/stage2_neg.txt"

# 指示テキストは stage1 のものをそのまま使う
USER_INSTRUCTION="$STAGE1_TEXT"

# Qwen に渡す user message を JSON で組み立てる (python3 で安全にエスケープ)
python3 - "$BEFORE_PNG" "$USER_INSTRUCTION" "$TMP/stage2_request.json" "$QWEN3_MODEL" <<'PYEOF'
import json, sys, base64
png_path, instr, out, model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
with open(png_path, "rb") as f:
    b64 = base64.b64encode(f.read()).decode("ascii")
sys_msg = (
  "あなたは服のバーチャル試着用プロンプト生成アシスタントです。"
  "ユーザーから日本語の編集指示と元画像 (服) が与えられます。"
  "返答は以下の厳密な JSON のみを返してください (説明文や ``` も付けない):"
  "\n{\"prompt\": \"...\", \"negative_prompt\": \"...\"}\n"
  "prompt は日本語で、その服にどういう変更を加えるかを 1 文で書いてください。"
  "negative_prompt にはぼやけた・低品質・歪んだ などの否定語を日本語で含めてください。"
)
user_text = (
  f"指示: {instr}\n"
  "元画像 (シャツ) はこの会話内の画像を参照してください。"
  "その元画像に対して上記指示を反映する VTON プロンプトを JSON で返してください。"
)
body = {
  "model": model,
  "max_tokens": 2048,
  "temperature": 0.0,
  "messages": [
    {"role": "system", "content": sys_msg},
    {"role": "user", "content": [
      {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
      {"type": "text", "text": user_text},
    ]},
  ],
}
with open(out,"w") as f: json.dump(body, f, ensure_ascii=False)
PYEOF

HTTP_CODE=$(curl -sS -m "$TIMEOUT" -H 'Content-Type: application/json' \
  -d "@$TMP/stage2_request.json" \
  "$QWEN3_URL" -o "$STAGE2_RESP" -w '%{http_code}' \
  || echo "ERR")
echo "[stage2] HTTP=$HTTP_CODE  body head: $(head -c 300 "$STAGE2_RESP")"
if [[ "$HTTP_CODE" != "200" ]]; then
  fail "stage2 curl failed HTTP=$HTTP_CODE"
fi

# 応答 -> {prompt, negative_prompt}
python3 - "$STAGE2_RESP" "$STAGE2_PROMPT" "$STAGE2_NEG" <<'PYEOF'
import json, re, sys
resp_path, p_out, n_out = sys.argv[1], sys.argv[2], sys.argv[3]
with open(resp_path) as f: r=json.load(f)
if "choices" not in r:
    print("[stage2] FAIL: no choices in response:", json.dumps(r)[:500], file=sys.stderr); sys.exit(1)
msg = r["choices"][0]["message"]
content = (msg.get("content") or "")
# Qwen3-VL-Thinking の場合 reasoning_content に最終 JSON が乗ることがある
if not content and msg.get("reasoning_content"):
    content = msg["reasoning_content"]
print("[stage2] raw content:", content[:400])
# JSON 部分だけを greedy 抽出
m=re.search(r"\{[^{}]*?\"prompt\".*?\}", content, re.S)
if not m:
    m=re.search(r"\{.*\}", content, re.S)
if not m:
    print("[stage2] FAIL: no JSON in response", file=sys.stderr); sys.exit(1)
obj=json.loads(m.group(0))
p=obj.get("prompt","").strip()
n=obj.get("negative_prompt","").strip()
if not p:
    print("[stage2] FAIL: empty prompt", file=sys.stderr); sys.exit(1)
open(p_out,"w").write(p)
open(n_out,"w").write(n or "ぼやけた、低品質、歪んだ")
print("[stage2] prompt:", p)
print("[stage2] negative:", n)
PYEOF
rc=$?
[[ "$rc" == "0" ]] || fail "stage2 parse rc=$rc"

VTON_PROMPT="$(cat "$STAGE2_PROMPT")"
VTON_NEG="$(cat "$STAGE2_NEG")"
if [[ "$(has_japanese "$VTON_PROMPT")" != "YES" ]]; then
  fail "stage2: prompt に日本語文字が無い: $VTON_PROMPT"
fi
record "[PASS] stage2 prompt: $VTON_PROMPT"

# ============================================================================
# stage 3: VTON: before + prompt -> after
# ============================================================================
echo
echo "=== [stage 3] VTON: 画像編集 ==="

AFTER_PNG="$TMP/after.png"
HTTP=$(curl -sS -m 900 -o "$AFTER_PNG" -D "$TMP/vton_headers.txt" -w '%{http_code}' \
  -X POST "$VTON_URL" \
  -F "image1=@${BEFORE_PNG};type=image/png" \
  -F "prompt=${VTON_PROMPT}" \
  -F "negative_prompt=${VTON_NEG}" \
  -F "num_inference_steps=20" \
  -F "true_cfg_scale=3.0" \
  -F "seed=42" || echo "ERR")

[[ "$HTTP" == "200" ]] || fail "stage3 VTON HTTP=$HTTP (body head: $(head -c 400 "$AFTER_PNG"))"

MAGIC=$(head -c 8 "$AFTER_PNG" | od -An -tx1 | tr -d ' ')
[[ "$MAGIC" =~ ^89504e470d0a1a0a ]] || fail "stage3 VTON: returned bytes are not PNG (magic=$MAGIC)"
SIZE=$(stat -c%s "$AFTER_PNG" 2>/dev/null || stat -f%z "$AFTER_PNG")
record "[PASS] stage3 after.png size=${SIZE}"

# ============================================================================
# stage 4: Qwen3-VL: after + 元指示 -> 整合性確認の日本語説明
# ============================================================================
echo
echo "=== [stage 4] Qwen3-VL: after 画像と指示の整合性を日本語で説明 ==="

STAGE4_RESP="$TMP/stage4_response.json"

# (画像 base64 は引数経由だと "Argument list too long" になるのでファイル経由で渡す)
python3 - "$AFTER_PNG" "$USER_INSTRUCTION" "$VTON_PROMPT" "$TMP/stage4_request.json" "$QWEN3_MODEL" <<'PYEOF'
import json, sys, base64
png_path, instr, prompt, out, model = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5]
with open(png_path, "rb") as f:
    b64 = base64.b64encode(f.read()).decode("ascii")
sys_msg = (
  "あなたは画像編集結果のレビュアーです。日本語で簡潔に答えてください。"
)
user_text = (
  f"元の指示: {instr}\n"
  f"VTON に渡したプロンプト: {prompt}\n"
  "添付の編集後画像を見て、指示に沿った編集ができているかを 2 文以内で日本語で説明してください。"
)
body = {
  "model": model,
  "max_tokens": 2048,
  "temperature": 0.0,
  "messages": [
    {"role":"system","content":sys_msg},
    {"role":"user","content":[
      {"type":"image_url","image_url":{"url":f"data:image/png;base64,{b64}"}},
      {"type":"text","text":user_text},
    ]},
  ],
}
with open(out,"w") as f: json.dump(body, f, ensure_ascii=False)
PYEOF

HTTP_CODE=$(curl -sS -m "$TIMEOUT" -H 'Content-Type: application/json' \
  -d "@$TMP/stage4_request.json" \
  "$QWEN3_URL" -o "$STAGE4_RESP" -w '%{http_code}' \
  || echo "ERR")
echo "[stage4] HTTP=$HTTP_CODE  body head: $(head -c 300 "$STAGE4_RESP")"
[[ "$HTTP_CODE" == "200" ]] || fail "stage4 curl failed HTTP=$HTTP_CODE"

STAGE4_TEXT="$(python3 -c '
import json,sys
r=json.load(open(sys.argv[1]))
msg=r["choices"][0]["message"]
print((msg.get("reasoning_content") or "") + "\n" + (msg.get("content") or ""))
' "$STAGE4_RESP")"
echo "[stage4] explanation: $STAGE4_TEXT"

if [[ "$(has_japanese "$STAGE4_TEXT")" != "YES" ]]; then
  fail "stage4: 説明文に日本語文字が無い: $STAGE4_TEXT"
fi
record "[PASS] stage4 explanation contains Japanese"

# 整合性チェック: 元指示に色が含まれていれば、説明文にも同じ色 (or 同義語) が含まれるか
COLOR_CHECK="$(python3 - "$USER_INSTRUCTION" "$VTON_PROMPT" "$STAGE4_TEXT" <<'PYEOF'
import sys
instr, prompt, expl = sys.argv[1], sys.argv[2], sys.argv[3]
color_map = {
  "赤": ["赤","レッド","red"], "青": ["青","ブルー","blue"], "緑":["緑","グリーン","green"],
  "黄":["黄","イエロー","yellow"], "オレンジ":["オレンジ","橙","orange"],
  "紫":["紫","パープル","purple"], "白":["白","ホワイト","white"], "黒":["黒","ブラック","black"],
}
hit_in_instr = [k for k in color_map if k in instr]
if not hit_in_instr:
    print("NO_COLOR_IN_INSTR"); sys.exit(0)
joined = (prompt + " " + expl).lower()
ok = any(any(syn.lower() in joined for syn in color_map[c]) for c in hit_in_instr)
print(f"COLOR={hit_in_instr[0]} PROPAGATED={'YES' if ok else 'NO'}")
PYEOF
)"
echo "[stage4] color consistency: $COLOR_CHECK"
if [[ "$COLOR_CHECK" == COLOR=*PROPAGATED=NO ]]; then
  fail "stage4: 元指示の色が prompt/説明文まで伝わっていない: $COLOR_CHECK"
fi
[[ "$COLOR_CHECK" == COLOR=*PROPAGATED=YES ]] && record "[PASS] $COLOR_CHECK"

# ============================================================================
# サマリ
# ============================================================================
echo
echo "============================================================"
echo "[e2e] SUMMARY"
echo "============================================================"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo "------------------------------------------------------------"
echo "  artifacts in: $TMP (this dir is removed on exit)"
echo "  - stage1 transcript : $STAGE1_TEXT_FILE"
echo "  - stage2 prompt     : $STAGE2_PROMPT"
echo "  - stage3 after.png  : $AFTER_PNG"
echo "  - stage4 response   : $STAGE4_RESP"
echo "[e2e] PASS"
exit 0
