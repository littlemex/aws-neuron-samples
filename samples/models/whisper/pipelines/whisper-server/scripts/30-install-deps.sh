#!/usr/bin/env bash
set -euo pipefail

# venv に aiohttp / soundfile を追加 (Neuron venv に標準では入っていない)、
# OS 側に ffmpeg / libsndfile1 を入れる。
# transformers と torch / torch_neuronx は venv 既存。

DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ffmpeg libsndfile1 >/dev/null 2>&1 || true
"${VENV}/bin/pip" install --quiet 'aiohttp>=3.9' 'soundfile>=0.12' 'numpy>=1.24' 2>&1 | tail -5 || true
echo '[OK] deps installed'
