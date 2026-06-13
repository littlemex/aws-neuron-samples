#!/usr/bin/env bash
set -euo pipefail

# config.json + safetensors が無い場合のみ snapshot_download。GGUF/GGML は除外。

sudo mkdir -p "$(dirname "${MODEL_DIR}")"
_owner=$(getent passwd ubuntu >/dev/null 2>&1 && echo 'ubuntu:ubuntu' || (getent passwd ec2-user >/dev/null 2>&1 && echo 'ec2-user:ec2-user') || echo 'root:root')
sudo chown -R "$_owner" "$(dirname "${MODEL_DIR}")"

if [ -f "${MODEL_DIR}/config.json" ] && ls "${MODEL_DIR}"/*.safetensors >/dev/null 2>&1; then
  echo "[OK] model already present"
  exit 0
fi

"${VENV}/bin/pip" install --quiet 'huggingface_hub' 2>&1 | tail -3 || true
"${VENV}/bin/python" -c "from huggingface_hub import snapshot_download; snapshot_download(repo_id='${MODEL_ID}', local_dir='${MODEL_DIR}', ignore_patterns=['*.gguf','*.ggml'])"
test -f "${MODEL_DIR}/config.json" || { echo "[NG] config.json missing after download"; exit 1; }
echo "[OK] model downloaded"
