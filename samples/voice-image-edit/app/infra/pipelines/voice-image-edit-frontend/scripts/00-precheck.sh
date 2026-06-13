#!/usr/bin/env bash
set -euo pipefail

# タスク説明: Node.js >= 18, curl, tar が居ることを確認。Next.js 14.2.5 の standalone は Node 18+ で動作する。

command -v node >/dev/null || { echo '[NG] node missing'; exit 1; }
node --version
node -e 'process.exit(process.versions.node.split(".")[0] >= 18 ? 0 : 1)' || { echo '[NG] node < 18'; exit 1; }
command -v curl >/dev/null || { echo '[NG] curl missing'; exit 1; }
command -v tar >/dev/null || { echo '[NG] tar missing'; exit 1; }
id "${FRONTEND_USER}" >/dev/null 2>&1 || { echo "[NG] user ${FRONTEND_USER} missing"; exit 1; }
echo '[OK] precheck'
