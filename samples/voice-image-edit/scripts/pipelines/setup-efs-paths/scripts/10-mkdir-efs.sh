#!/usr/bin/env bash
set -euo pipefail

# Task: mkdir EFS dirs (models / voice-image-edit)
# EFS 上に永続化先 directory を作る。既にあれば noop。

mkdir -p "${EFS_ROOT}/${MODELS_DIR_NAME}"
mkdir -p "${EFS_ROOT}/${MODELS_DIR_NAME}/hf-cache"
mkdir -p "${EFS_ROOT}/${MODELS_DIR_NAME}/whisper-large-v3-neuron"
mkdir -p "${EFS_ROOT}/${MODELS_DIR_NAME}/qwen-image-edit-compiled"
mkdir -p "${EFS_ROOT}/${MODELS_DIR_NAME}/qwen3-vl-compiled"
mkdir -p "${EFS_ROOT}/${VIE_DIR_NAME}"
mkdir -p "${EFS_ROOT}/${VIE_DIR_NAME}/whisper-server"
mkdir -p "${EFS_ROOT}/${VIE_DIR_NAME}/qwen3-vl-server"
mkdir -p "${EFS_ROOT}/${VIE_DIR_NAME}/qwen-image-edit-server"
mkdir -p "${EFS_ROOT}/${VIE_DIR_NAME}/qwen-image-edit-compile"
_owner=$(getent passwd ubuntu >/dev/null 2>&1 && echo 'ubuntu:ubuntu' || (getent passwd ec2-user >/dev/null 2>&1 && echo 'ec2-user:ec2-user') || echo 'root:root')
chown -R "$_owner" "${EFS_ROOT}/${MODELS_DIR_NAME}" "${EFS_ROOT}/${VIE_DIR_NAME}"
echo "[OK] EFS dirs prepared (owner=$_owner)"
