#!/usr/bin/env bash
set -euo pipefail

# Task: daemon-reload + enable + start (stop then start, not restart)
# Description (original):
#   systemd を再読込してサービスを有効化・起動する。restart は unit file を変更した直後に
#   古い unit で再起動するケースがあるので、必ず stop してから start する。
#   最後に is-active で状態確認。

systemctl daemon-reload
systemctl enable voice-image-edit-stream.service
systemctl stop voice-image-edit-stream.service 2>/dev/null || true
systemctl reset-failed voice-image-edit-stream.service 2>/dev/null || true
systemctl start voice-image-edit-stream.service
for i in 1 2 3 4 5 6 7 8 9 10; do
  systemctl is-active voice-image-edit-stream.service >/dev/null 2>&1 && break
  sleep 1
done
systemctl is-active voice-image-edit-stream.service >/dev/null 2>&1 || {
  echo '[NG] service did not become active'
  systemctl status voice-image-edit-stream.service --no-pager | head -20
  journalctl -u voice-image-edit-stream.service -n 30 --no-pager
  exit 1
}
echo '[OK] service started'
