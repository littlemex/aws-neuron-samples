#!/usr/bin/env bash
set -euo pipefail

# Task: Enable and start service
# Enable and start the code-server and nginx systemd services

echo '==> Enabling and starting Code Server service'
systemctl daemon-reload

# Enable service
systemctl enable --now "code-server@${USER}"
echo 'Code Server service enabled'

# Restart service to apply configuration
systemctl restart "code-server@${USER}"
systemctl restart nginx
echo 'Services restarted'

# Wait for service to start
sleep 5

# Check status
if systemctl is-active --quiet "code-server@${USER}"; then
  echo 'Code Server is running successfully'
  systemctl status "code-server@${USER}" --no-pager | head -20
else
  echo 'ERROR: Code Server failed to start'
  systemctl status "code-server@${USER}" --no-pager
  exit 1
fi

if systemctl is-active --quiet nginx; then
  echo 'nginx is running successfully'
else
  echo 'WARNING: nginx failed to start'
  systemctl status nginx --no-pager
fi
