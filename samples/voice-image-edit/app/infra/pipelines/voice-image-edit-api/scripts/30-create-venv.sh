#!/usr/bin/env bash
# Make sure $API_DIR/venv exists and has every dependency from
# requirements.txt installed. Idempotent on a healthy venv: the existence
# check is "bin/python is executable", not just "the directory exists",
# because a half-deleted venv from a previous deploy can leave the dir but
# break python imports.
set -euo pipefail

apt-get -y install python3-venv >/dev/null 2>&1 \
  || { echo "[NG] apt-get install python3-venv failed"; exit 1; }

# Recreate the venv silently if bin/python no longer works.
if ! "$API_DIR/venv/bin/python" -c 'import sys' >/dev/null 2>&1; then
  echo "[INFO] venv missing or broken - recreating"
  rm -rf "$API_DIR/venv"
  sudo -u "$API_USER" python3 -m venv "$API_DIR/venv"
fi

sudo -u "$API_USER" "$API_DIR/venv/bin/pip" install --upgrade pip --quiet
sudo -u "$API_USER" "$API_DIR/venv/bin/pip" install --quiet -r "$API_DIR/requirements.txt"

# Defence in depth: if pip install --quiet ever silently no-ops on an empty
# requirements.txt, the next task would happily start uvicorn with the
# wrong runtime. Verifying bin/uvicorn forces an immediate failure here.
test -x "$API_DIR/venv/bin/python"  || { echo "[NG] venv/bin/python not executable"; exit 1; }
test -x "$API_DIR/venv/bin/uvicorn" || { echo "[NG] venv/bin/uvicorn missing after pip install"; exit 1; }

chown -R "$API_USER:$API_USER" "$API_DIR/venv"
echo "[OK] venv ready"
