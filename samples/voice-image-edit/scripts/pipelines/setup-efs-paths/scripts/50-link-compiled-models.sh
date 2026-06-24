#!/usr/bin/env bash
set -euo pipefail

# Task: Symlink /mnt/local/compiled_models_tp16 -> EFS/models/qwen-image-edit-compiled
# compile.sh v3_tp16 / qwen-image-edit-prepare / qwen-image-edit-server はいずれも
# /mnt/local/compiled_models_tp16 を出力・参照先に使う (compile.sh は VERSION_MODE
# ごとに _tp8 / _tp16 / _tp32 と接尾辞を変える)。ここを EFS の
# qwen-image-edit-compiled/ に link しておかないと、NVMe は CB recover のたびに
# wipe されるので毎回フル再 compile (90-120 分) が走ってしまう。
# NVMe 上の既存内容があれば一旦 EFS に rsync する。

TARGET="${EFS_ROOT}/${MODELS_DIR_NAME}/qwen-image-edit-compiled"
if [ -L /mnt/local/compiled_models_tp16 ]; then
  current=$(readlink -f /mnt/local/compiled_models_tp16)
  if [ "$current" = "$TARGET" ]; then
    echo '[OK] compiled_models already symlinked'
  else
    rm /mnt/local/compiled_models_tp16
    ln -sfn "${TARGET}" /mnt/local/compiled_models_tp16
  fi
elif [ -d /mnt/local/compiled_models_tp16 ] && [ "$(ls -A /mnt/local/compiled_models_tp16 2>/dev/null)" ]; then
  echo '[INFO] migrating compiled_models to EFS (this may take ~10 min for ~80GB)'
  rsync -a --info=progress2 /mnt/local/compiled_models_tp16/ "${TARGET}/"
  rm -rf /mnt/local/compiled_models_tp16
  ln -sfn "${TARGET}" /mnt/local/compiled_models_tp16
else
  if [ -d /mnt/local/compiled_models_tp16 ]; then
    rmdir /mnt/local/compiled_models_tp16 2>/dev/null || rm -rf /mnt/local/compiled_models_tp16
  fi
  ln -sfn "${TARGET}" /mnt/local/compiled_models_tp16
fi

# /mnt/local lives on NVMe ephemeral storage and is wiped on every restart.
# Install a oneshot systemd unit that replays the same ln -sfn at boot so the
# symlink does not silently vanish across stop+start.
# This block runs on every invocation (idempotent): the unit body is
# rewritten with the current TARGET so re-runs cannot drift.
cat > /etc/systemd/system/restore-nvme-symlinks.service <<EOF
[Unit]
Description=Recreate NVMe symlinks under /mnt/local after every boot
After=local-fs.target
Wants=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/bash -c 'mkdir -p /mnt/local && ln -sfn ${TARGET} /mnt/local/compiled_models_tp16'

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now restore-nvme-symlinks.service

ls -ld /mnt/local/compiled_models_tp16
echo '[OK] /mnt/local/compiled_models_tp16 -> EFS'
