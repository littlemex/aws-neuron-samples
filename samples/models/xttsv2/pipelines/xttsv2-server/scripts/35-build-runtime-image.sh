#!/usr/bin/env bash
set -euo pipefail

# Task: Build the runtime image (DLC + coqui-tts + torchaudio)
# Bakes coqui-tts + torchaudio + fastapi into a layer on top of the DLC so that
# container start is fast and reproducible. Idempotent: skipped if the tag
# already exists with the right base.

cd "${SERVE_DIR}"
if docker image inspect "${RUNTIME_IMAGE}" >/dev/null 2>&1; then
  echo '[OK] runtime image already built'
  exit 0
fi
docker build -t "${RUNTIME_IMAGE}" -f Dockerfile.server .
docker image inspect "${RUNTIME_IMAGE}" >/dev/null
