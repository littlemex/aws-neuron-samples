#!/usr/bin/env bash
# daemon-reload, then stop+start the unit (NOT restart): "systemctl restart"
# can fire just before systemd notices the unit file changed on disk and
# end up restarting under the OLD definition. The explicit stop+start
# ordering avoids that race entirely.
set -euo pipefail

systemctl daemon-reload
systemctl enable voice-image-edit-api.service

systemctl stop voice-image-edit-api.service        2>/dev/null || true
systemctl reset-failed voice-image-edit-api.service 2>/dev/null || true
systemctl start voice-image-edit-api.service

# Wait up to 10s for the unit to become active. uvicorn may take a beat to
# bind the socket; we want to fail loudly here instead of dragging the
# error into 60-health-check.
for _ in 1 2 3 4 5 6 7 8 9 10; do
  systemctl is-active voice-image-edit-api.service >/dev/null 2>&1 && break
  sleep 1
done

if ! systemctl is-active voice-image-edit-api.service >/dev/null 2>&1; then
  echo "[NG] service did not become active"
  systemctl status voice-image-edit-api.service --no-pager | head -20 || true
  journalctl -u voice-image-edit-api.service -n 30 --no-pager       || true
  exit 1
fi

echo "[OK] service started"
