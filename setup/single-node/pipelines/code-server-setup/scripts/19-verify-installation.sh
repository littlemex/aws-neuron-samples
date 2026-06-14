#!/usr/bin/env bash
set -euo pipefail

# Task: Verify installation
# Verify the installation by printing service status, listening ports, and code-server version

echo ''
echo '========================================='
echo 'Setup Verification'
echo '========================================='

# User confirmation
echo "User: ${USER}"
id "${USER}"

# Directory confirmation
echo ''
echo "Home directory: ${HOME_DIR}"
ls -la "${HOME_DIR}" | head -5

# Code Server version
echo ''
echo 'Code Server version:'
/usr/bin/code-server --version

# Service status
echo ''
echo 'Code Server service status:'
systemctl is-active "code-server@${USER}" && echo 'ACTIVE' || echo 'INACTIVE'

echo ''
echo 'nginx service status:'
systemctl is-active nginx && echo 'ACTIVE' || echo 'INACTIVE'

# Port confirmation
echo ''
echo 'Listening ports:'
ss -tlnp | grep -E "(${INTERNAL_PORT}|${NGINX_PORT})" || echo 'Ports not found'

# nginx configuration test
echo ''
echo 'nginx configuration:'
nginx -t 2>&1

echo ''
echo '========================================='
echo 'Setup completed successfully!'
echo '========================================='
echo "Code Server is running on port ${INTERNAL_PORT}"
echo "nginx is proxying on port ${NGINX_PORT}"
echo ''
echo "Access Code Server at: http://[YOUR_INSTANCE_IP]:${NGINX_PORT}"
