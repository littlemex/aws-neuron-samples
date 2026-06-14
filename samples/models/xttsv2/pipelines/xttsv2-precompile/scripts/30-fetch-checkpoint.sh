#!/usr/bin/env bash
set -euo pipefail

# Task: Download XTTSv2 checkpoint via Coqui TTS if missing
# Description: Ensure ${XTTS_MODEL_DIR}/model.pth + config.json exist.
# Runs Coqui's ModelManager.download_model inside the DLC so we do not pollute the host venv.
# Idempotent: skipped when model.pth already exists.

if [ -f "${COMPILED_MODEL_PATH}/.precompile_skipped" ] && [ "${FORCE_RECOMPILE}" != 'true' ]; then
  echo '[OK] skipped (cached)'
  exit 0
fi

if [ -f "${XTTS_MODEL_DIR}/model.pth" ] && [ -f "${XTTS_MODEL_DIR}/config.json" ]; then
  echo '[OK] checkpoint already present'
  exit 0
fi

mkdir -p "${XTTS_MODEL_DIR}"

cat > /tmp/xttsv2_dl_ckpt.py <<'PYEOF'
import os, shutil, glob
from TTS.utils.manage import ModelManager
m = ModelManager()
result = m.download_model(os.environ['XTTSV2_MODEL_ID'])
if isinstance(result, (list, tuple)) and len(result) >= 1:
    src = result[0]
else:
    raise SystemExit(f'unexpected download_model return: {result!r}')
dst = os.environ['XTTSV2_DEST_DIR']
os.makedirs(dst, exist_ok=True)
for p in glob.glob(os.path.join(str(src), '*')):
    shutil.copy(p, os.path.join(dst, os.path.basename(p)))
print(f'[OK] checkpoint copied to {dst}')
PYEOF

docker run --rm \
  -e COQUI_TOS_AGREED=1 \
  -e XTTSV2_MODEL_ID="${MODEL_ID}" \
  -e XTTSV2_DEST_DIR=/dst \
  -v "${XTTS_MODEL_DIR}":/dst \
  -v /tmp/xttsv2_dl_ckpt.py:/tmp/xttsv2_dl_ckpt.py:ro \
  --entrypoint /bin/bash \
  "${DLC_IMAGE}" \
  -lc "pip install --quiet 'coqui-tts==0.26.*' 'soundfile>=0.12' 2>&1 | tail -5 && python /tmp/xttsv2_dl_ckpt.py"

test -f "${XTTS_MODEL_DIR}/model.pth" \
  || { echo '[NG] model.pth missing after download'; exit 1; }
test -f "${XTTS_MODEL_DIR}/config.json" \
  || { echo '[NG] config.json missing after download'; exit 1; }

echo "[OK] checkpoint ready at ${XTTS_MODEL_DIR}"
