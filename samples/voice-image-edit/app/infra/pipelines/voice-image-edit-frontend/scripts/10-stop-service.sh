#!/usr/bin/env bash
set -euo pipefail

# タスク説明: systemd unit があれば一旦止める。Re-deploy 時に古いプロセスがファイルを掴んでいると
# 20-deploy-tarball の rm -rf が部分失敗するため、必ず先に止める。冪等性のため失敗しても続行。

systemctl stop voice-image-edit-frontend.service 2>/dev/null || true
systemctl reset-failed voice-image-edit-frontend.service 2>/dev/null || true
for i in 1 2 3 4 5; do
  systemctl is-active voice-image-edit-frontend.service >/dev/null 2>&1 || break
  sleep 1
done
echo '[OK] stopped'
