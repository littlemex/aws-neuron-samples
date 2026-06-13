#!/usr/bin/env bash
# Pull the API backend tarball (presigned S3 URL), extract it under API_DIR,
# and re-set ownership. The directory is wiped before extract EXCEPT for
# the venv/ subdirectory, which the next task (30-create-venv) is allowed
# to manage. Keeping the venv across runs lets pip install --upgrade do its
# usual diff-only work instead of rebuilding from scratch.
set -euo pipefail

mkdir -p "$API_DIR"

# `find -mindepth 1 -not -name venv` deletes everything under API_DIR except
# the venv directory, which is preserved for 30-create-venv to update.
find "$API_DIR" -mindepth 1 -maxdepth 1 -not -name venv -exec rm -rf {} +

tmp=$(mktemp /tmp/voice-image-edit-api.XXXXXX.tar.gz)
trap 'rm -f "$tmp"' EXIT

curl -fsSL "$API_TARBALL_URL" -o "$tmp"
tar -C "$API_DIR" -xzf "$tmp"

# Sanity-check that the tarball is what we expect, since a quietly empty
# tarball would survive extraction but break 30-create-venv with a misleading
# error.
test -f "$API_DIR/app.py"          || { echo "[NG] app.py missing after extract";          exit 1; }
test -f "$API_DIR/requirements.txt"|| { echo "[NG] requirements.txt missing";              exit 1; }
test -f "$API_DIR/contracts.py"    || { echo "[NG] contracts.py missing";                  exit 1; }
test -d "$API_DIR/engines"         || { echo "[NG] engines/ missing";                      exit 1; }

# Re-own everything except venv (which 30-create-venv handles).
find "$API_DIR" -mindepth 1 -maxdepth 1 -not -name venv \
  -exec chown -R "$API_USER:$API_USER" {} +
chown "$API_USER:$API_USER" "$API_DIR"

echo "[OK] tarball deployed (venv preserved)"
