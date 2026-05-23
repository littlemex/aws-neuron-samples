#!/usr/bin/env bash
# 日本語サンプル wav (16kHz mono int16) を生成して tests/_assets/sample_ja.wav に保存。
#
# 方針 (Neuron 初期化を避けるためシステム python3 を使う):
#   1) gTTS で日本語 mp3 を取得
#   2) miniaudio (pure-Python wheel) で mp3 をデコードして PCM 化
#   3) 16kHz / mono / int16 へリサンプリングして wav 書き出し
#
# 参考: https://zenn.dev/tosshi/articles/f6c49165c90e6d
set -uo pipefail

ASSETS_DIR="$(cd "$(dirname "$0")" && pwd)/_assets"
mkdir -p "$ASSETS_DIR"
OUT_WAV="$ASSETS_DIR/sample_ja.wav"
TEXT="${TEXT:-こんにちは。これは音声認識のテストです。}"
PY="${PY:-/usr/bin/python3}"

echo "[prepare] target: $OUT_WAV"
echo "[prepare] text:   $TEXT"
echo "[prepare] python: $PY"

if [[ -f "$OUT_WAV" && "${FORCE:-0}" != "1" ]]; then
  echo "[prepare] already exists (set FORCE=1 to regenerate)"
  exit 0
fi

# 必要パッケージを user-site にインストール (system 全体を汚さない)
echo "[prepare] installing gtts + miniaudio into ~/.local ..."
"$PY" -m pip install --quiet --user --break-system-packages gtts miniaudio 2>&1 | sed 's/^/  pip: /' | tail -5

"$PY" - "$OUT_WAV" "$TEXT" <<'PYEOF'
import io, sys, wave, math
from gtts import gTTS
import miniaudio

out, text = sys.argv[1], sys.argv[2]

# 1) gTTS -> mp3 bytes
buf = io.BytesIO()
gTTS(text=text, lang='ja').write_to_fp(buf)
mp3 = buf.getvalue()
print(f"[prepare] mp3 bytes: {len(mp3)}")

# 2) miniaudio で mp3 デコード -> PCM
decoded = miniaudio.decode(mp3, output_format=miniaudio.SampleFormat.SIGNED16,
                           nchannels=1, sample_rate=16000)
samples = decoded.samples  # array.array("h")
print(f"[prepare] decoded samples: {len(samples)}  sr={decoded.sample_rate}  ch={decoded.nchannels}")

# 3) wav 書き出し (16kHz mono int16)
with wave.open(out, "wb") as w:
    w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
    w.writeframes(samples.tobytes())
print(f"[prepare] wrote {out}")
PYEOF
rc=$?

if [[ "$rc" != "0" ]]; then
  cat <<EOF
[prepare] FAIL: 自動生成に失敗しました (rc=$rc)。
  手動で 16kHz mono int16 の wav を用意して以下に置いてください:
    $OUT_WAV
  ヒント:
    - macOS:  say -v Kyoko -o sample.aiff '$TEXT'; afconvert sample.aiff -d LEI16@16000 -c 1 -f WAVE $OUT_WAV
    - Linux:  espeak-ng -v ja -w sample.wav '$TEXT' && sox sample.wav -r 16000 -c 1 -b 16 $OUT_WAV
EOF
  exit 1
fi

ls -la "$OUT_WAV"
"$PY" -c "
import wave
with wave.open('$OUT_WAV','rb') as w:
    print('  framerate=',w.getframerate(),'  channels=',w.getnchannels(),'  width=',w.getsampwidth(),'  frames=',w.getnframes())
"
