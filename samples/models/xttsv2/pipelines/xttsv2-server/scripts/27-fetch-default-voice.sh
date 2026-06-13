#!/usr/bin/env bash
set -euo pipefail

# Task: Seed ${XTTSV2_DEFAULT_VOICE} with a Polly-generated reference WAV
# XTTSv2 is a voice-cloning model — without an on-disk reference it falls back
# to a built-in English-native speaker, which produces obviously non-native
# Japanese audio. We synthesise a short Japanese sample with Amazon Polly
# (${XTTSV2_REFERENCE_VOICE_ID}/neural) and convert it to 24 kHz mono WAV so
# XTTSv2 clones a Japanese-native timbre. Idempotent: skipped when
# reference.wav already exists. Polly Neural is not yet GA in sa-east-1 so we
# always call us-east-1 for the synthesise call (configurable via
# XTTSV2_REFERENCE_VOICE_REGION).

REF_DIR="${XTTSV2_VOICES_DIR}/${XTTSV2_DEFAULT_VOICE}"
REF_WAV="${REF_DIR}/reference.wav"
if [ -f "${REF_WAV}" ]; then echo '[OK] reference.wav already exists, skip'; exit 0; fi
if ! command -v ffmpeg >/dev/null; then
  echo '[INFO] installing ffmpeg'
  DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1 && \
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg >/dev/null 2>&1 || \
  { echo '[WARN] ffmpeg install failed; skipping default voice seed (server falls back to built-in speaker)'; exit 0; }
fi
TMP_MP3=$(mktemp /tmp/xttsv2-ref.XXXXXX.mp3)
trap 'rm -f $TMP_MP3' EXIT
if ! aws polly synthesize-speech \
    --region "${XTTSV2_REFERENCE_VOICE_REGION}" \
    --engine neural \
    --voice-id "${XTTSV2_REFERENCE_VOICE_ID}" \
    --language-code ja-JP \
    --output-format mp3 \
    --text "${XTTSV2_REFERENCE_VOICE_TEXT}" \
    "${TMP_MP3}" >/dev/null 2>&1; then
  echo '[WARN] Polly synthesize-speech failed (likely missing polly:SynthesizeSpeech on the instance role); skipping default voice seed (server falls back to built-in speaker)'
  exit 0
fi
test -s "${TMP_MP3}" || { echo '[WARN] Polly produced empty mp3; skipping'; exit 0; }
ffmpeg -y -hide_banner -loglevel error -i "${TMP_MP3}" -ar 24000 -ac 1 -c:a pcm_s16le "${REF_WAV}"
test -s "${REF_WAV}" || { echo '[WARN] ffmpeg produced empty wav; skipping'; exit 0; }
chown -R "${SERVE_USER}:${SERVE_USER}" "${REF_DIR}"
echo "[OK] reference.wav written: $(stat -c %s "${REF_WAV}") bytes"
