#!/usr/bin/env bash
set -euo pipefail

# Task: Symlink /opt/voice-image-edit -> EFS/voice-image-edit
# サーバ source は EFS に置いて compile artifact 同様に永続化する。
# systemd unit 側は /opt/voice-image-edit/<server>/ を見るので透明。

TARGET="${EFS_ROOT}/${VIE_DIR_NAME}"
if [ -L /opt/voice-image-edit ]; then
  current=$(readlink -f /opt/voice-image-edit)
  if [ "$current" = "$TARGET" ]; then echo '[OK] /opt/voice-image-edit already symlinked'; exit 0; fi
  rm /opt/voice-image-edit
elif [ -d /opt/voice-image-edit ] && [ "$(ls -A /opt/voice-image-edit 2>/dev/null)" ]; then
  echo '[INFO] migrating /opt/voice-image-edit contents to EFS'
  rsync -a --info=progress2 /opt/voice-image-edit/ "${TARGET}/"
  rm -rf /opt/voice-image-edit
elif [ -d /opt/voice-image-edit ]; then
  rmdir /opt/voice-image-edit 2>/dev/null || rm -rf /opt/voice-image-edit
fi
ln -sfn "${TARGET}" /opt/voice-image-edit
ls -ld /opt/voice-image-edit
echo '[OK] /opt/voice-image-edit -> EFS'
