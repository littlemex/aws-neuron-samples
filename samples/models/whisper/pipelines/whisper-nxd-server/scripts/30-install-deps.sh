#!/usr/bin/env bash
set -euo pipefail

# タスク説明 (原文):
# venv に aiohttp / soundfile / openai-whisper を追加 (NxD venv に標準では入っていない)、
# OS 側に ffmpeg / libsndfile1 を入れる。

DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg libsndfile1 >/dev/null 2>&1 || true
"${VENV}/bin/pip" install --quiet 'aiohttp>=3.9' 'soundfile>=0.12' 'numpy>=1.24' 2>&1 | tail -5 || true
if ! "${VENV}/bin/python" -c 'import whisper' 2>/dev/null; then
  "${VENV}/bin/pip" install --no-deps openai-whisper 2>&1 | tail -5
  "${VENV}/bin/pip" install tiktoken numba more-itertools 2>&1 | tail -5
fi
"${VENV}/bin/python" -c 'import whisper; print("openai-whisper:", whisper.__version__)'
echo "[OK] deps installed"
