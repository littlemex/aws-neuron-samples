#!/usr/bin/env bash
set -euo pipefail

# Task: Precheck python3 + curl + tar
# Description (original):
#   Python 3.10+ (Ubuntu 22.04 / 24.04 default) と curl/tar が入っていることを確認する。

command -v python3 >/dev/null || { echo '[NG] python3 missing'; exit 1; }
python3 --version
command -v curl >/dev/null || { echo '[NG] curl missing'; exit 1; }
command -v tar >/dev/null || { echo '[NG] tar missing'; exit 1; }
id "${STREAM_USER}" >/dev/null 2>&1 || { echo "[NG] user ${STREAM_USER} missing"; exit 1; }
python3 -m venv --help >/dev/null 2>&1 || { echo '[NG] python3-venv module missing; run: apt-get install python3-venv'; exit 1; }
echo '[OK] precheck'
