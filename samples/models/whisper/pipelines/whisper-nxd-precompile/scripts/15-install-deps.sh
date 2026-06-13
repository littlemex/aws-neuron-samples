#!/usr/bin/env bash
set -euo pipefail

# NxD Whisper の import に必要な openai-whisper を入れる (no-deps で torch を壊さない)。
# 既に入っていれば skip。

if "${VENV}/bin/python" -c 'import whisper' 2>/dev/null; then
  echo '[OK] openai-whisper already installed'
  exit 0
fi

"${VENV}/bin/pip" install --no-deps openai-whisper 2>&1 | tail -5
"${VENV}/bin/pip" install tiktoken numba more-itertools 2>&1 | tail -5
"${VENV}/bin/python" -c 'import whisper; print("[OK] openai-whisper:", whisper.__version__)'
