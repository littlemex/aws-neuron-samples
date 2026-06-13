#!/usr/bin/env bash
# Verify that the host has the bare minimum tools the rest of the pipeline
# needs, and that the runner did inject every required environment value.
# Required vars are guaranteed non-empty by the runner, so we only assert
# that python/curl/tar are present and that the user account exists.
set -euo pipefail

command -v python3 >/dev/null || { echo "[NG] python3 missing"; exit 1; }
python3 --version

command -v curl >/dev/null || { echo "[NG] curl missing"; exit 1; }
command -v tar  >/dev/null || { echo "[NG] tar missing";  exit 1; }

id "$API_USER" >/dev/null 2>&1 \
  || { echo "[NG] user $API_USER missing"; exit 1; }

# python3-venv is shipped separately from python3 on Debian/Ubuntu.
python3 -m venv --help >/dev/null 2>&1 \
  || { echo "[NG] python3-venv module missing; install with: apt-get install python3-venv"; exit 1; }

echo "[OK] precheck"
