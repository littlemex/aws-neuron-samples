#!/usr/bin/env bash
# 共通: EFS / インスタンスローカルのパス定義
# CB 終了で消えるディレクトリ:
#   - /models                     (モデルウェイト: Qwen3-VL, whisper-large-v3-neuron)
#   - /opt/dlami/nvme/compiled_models  (Qwen-Image-Edit Neuron compile artifacts)
# EFS 上のバックアップ先 (永続):
#   - ${EFS_ROOT}/efs-backup/models
#   - ${EFS_ROOT}/efs-backup/compiled_models
#   - ${EFS_ROOT}/efs-backup/neuron-cache  (compile cache)
# EFS_ROOT は実行環境の EFS マウント配下を指定すること (例: /mnt/efs/voice-image-edit)。

EFS_ROOT="${EFS_ROOT:-/mnt/efs/voice-image-edit}"
EFS_BACKUP="${EFS_BACKUP:-${EFS_ROOT}/efs-backup}"

LOCAL_MODELS="${LOCAL_MODELS:-/models}"
LOCAL_COMPILED="${LOCAL_COMPILED:-/opt/dlami/nvme/compiled_models}"
LOCAL_NEURON_CACHE="${LOCAL_NEURON_CACHE:-/var/tmp/neuron-compile-cache}"

EFS_MODELS="${EFS_BACKUP}/models"
EFS_COMPILED="${EFS_BACKUP}/compiled_models"
EFS_NEURON_CACHE="${EFS_BACKUP}/neuron-cache"
