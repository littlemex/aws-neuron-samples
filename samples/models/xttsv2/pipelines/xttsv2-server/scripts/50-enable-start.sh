#!/usr/bin/env bash
set -euo pipefail

# Task: daemon-reload + enable + start xttsv2-server (stop then start, not restart)
# Reload systemd and bring the service up.
# restart は unit file を変更した直後に古い unit で再起動するケースがあり、
# それで 60-health-check が timeout する事故が再現した。
# 必ず stop してから start する。最後に is-active で状態確認。

systemctl daemon-reload
systemctl enable xttsv2-server.service
systemctl stop xttsv2-server.service 2>/dev/null || true
systemctl reset-failed xttsv2-server.service 2>/dev/null || true
systemctl start xttsv2-server.service
for i in 1 2 3 4 5 6 7 8 9 10; do
  systemctl is-active xttsv2-server.service >/dev/null 2>&1 && break
  sleep 1
done
systemctl is-active xttsv2-server.service >/dev/null 2>&1 || {
  echo '[NG] service did not become active'
  systemctl status xttsv2-server.service --no-pager | head -20
  journalctl -u xttsv2-server.service -n 30 --no-pager
  exit 1
}
echo '[OK] service started'
