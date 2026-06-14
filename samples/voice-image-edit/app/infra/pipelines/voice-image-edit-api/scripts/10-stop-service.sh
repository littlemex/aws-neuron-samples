#!/usr/bin/env bash
# Stop the API systemd unit if it is running, and clear any failed state.
# We deliberately tolerate failures here so that the very first deploy
# (where the unit does not yet exist) does not fail the pipeline.
set -euo pipefail

systemctl stop voice-image-edit-api.service        2>/dev/null || true
systemctl reset-failed voice-image-edit-api.service 2>/dev/null || true

# Wait briefly for the service to actually exit so the next task can
# rewrite venv/ files without "text file busy" surprises.
for _ in 1 2 3 4 5; do
  systemctl is-active voice-image-edit-api.service >/dev/null 2>&1 || break
  sleep 1
done

echo "[OK] stopped"
