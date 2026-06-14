#!/usr/bin/env bash
set -euo pipefail

# Task: Ensure venv + install dependencies (idempotent on bin/python)
# Description (original):
#   venv の存在を fingerprint ではなく実体 (bin/python が実行可能か) で判定する。
#   壊れた venv が残っている場合は黙って作り直す。requirements は毎回 pip install で更新。
#   最後に bin/uvicorn の存在を必ず検証して、後続 50-enable-start が ExecStart で
#   203/EXEC を踏まないよう保証する。

apt-get -y install python3-venv >/dev/null 2>&1 || { echo '[NG] apt-get install python3-venv failed'; exit 1; }
if ! "${STREAM_DIR}/venv/bin/python" -c 'import sys' >/dev/null 2>&1; then
  echo '[INFO] venv missing or broken — recreating'
  rm -rf "${STREAM_DIR}/venv"
  sudo -u "${STREAM_USER}" python3 -m venv "${STREAM_DIR}/venv"
fi
sudo -u "${STREAM_USER}" "${STREAM_DIR}/venv/bin/pip" install --upgrade pip --quiet
sudo -u "${STREAM_USER}" "${STREAM_DIR}/venv/bin/pip" install --quiet -r "${STREAM_DIR}/requirements.txt"
test -x "${STREAM_DIR}/venv/bin/python" || { echo '[NG] venv/bin/python not executable after setup'; exit 1; }
test -x "${STREAM_DIR}/venv/bin/uvicorn" || { echo '[NG] venv/bin/uvicorn missing after pip install'; exit 1; }
chown -R "${STREAM_USER}:${STREAM_USER}" "${STREAM_DIR}/venv"
echo '[OK] venv ready'
