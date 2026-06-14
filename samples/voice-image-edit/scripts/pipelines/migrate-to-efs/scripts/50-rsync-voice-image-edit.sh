#!/usr/bin/env bash
set -euo pipefail

# サーバ source (whisper-server, qwen3-vl-server, qwen-image-edit-server, qwen-image-edit-compile)
# を EFS に持っていく。 どれも ~MB-GB クラス。

if [ -L /opt/voice-image-edit ]; then echo '[OK] already symlinked'; exit 0; fi
if [ -d /opt/voice-image-edit ] && [ "$(ls -A /opt/voice-image-edit 2>/dev/null)" ]; then
  mkdir -p "${EFS_ROOT}/${VIE_DIR_NAME}"
  rsync -a --info=stats2,progress2 /opt/voice-image-edit/ "${EFS_ROOT}/${VIE_DIR_NAME}/"
  echo '[OK] voice-image-edit rsync done'
else
  echo '[INFO] voice-image-edit empty/missing, skip'
fi
