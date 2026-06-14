#!/usr/bin/env bash
set -euo pipefail

# Task: Ensure voice reference dir exists
# Create ${XTTSV2_VOICES_DIR}/${XTTSV2_DEFAULT_VOICE} so the server has a place
# for voice references. Voice cloning uses the wav files placed under that dir;
# the next step seeds it with a Polly-generated sample so cloning works
# out-of-the-box.

mkdir -p "${XTTSV2_VOICES_DIR}/${XTTSV2_DEFAULT_VOICE}"
chown -R "${SERVE_USER}:${SERVE_USER}" "${XTTSV2_VOICES_DIR}"
echo "[OK] voices dir ready: ${XTTSV2_VOICES_DIR}"
