#!/usr/bin/env bash
set -euo pipefail

# Task: Configure nginx
# Configure nginx as a reverse proxy in front of code-server with long timeouts and WebSocket
# support; reset any conflicting default sites

echo '==> Configuring nginx'

# ========================================
# Remove any previous nginx configuration that could conflict with ours
# ========================================
echo 'Cleaning up existing nginx configurations...'

# Drop any previous code-server site configuration
rm -f /etc/nginx/conf.d/code-server.conf
rm -f /etc/nginx/sites-enabled/code-server
rm -f /etc/nginx/sites-available/code-server

# Drop the default site so our config is the only server block
rm -f /etc/nginx/sites-enabled/default

echo 'Cleanup completed'

# ========================================
# Use the Debian/Ubuntu sites-available + sites-enabled convention
# ========================================
echo 'Creating new nginx configuration...'

# Unquoted heredoc so ${NGINX_PORT} and ${INTERNAL_PORT} are substituted.
# Dollar signs that must be literal nginx variables are escaped with backslash.
cat > /etc/nginx/sites-available/code-server <<EOF
server {
    # SSM-only access pattern: nginx listens on 0.0.0.0 but the security group
    # attached by the CDK stack has no ingress rules. Inbound traffic is reachable
    # only through AWS-StartPortForwardingSession (SSM Session Manager tunnels).
    # This avoids exposing an unauthenticated HTTP endpoint to the public internet.
    listen ${NGINX_PORT} default_server;
    listen [::]:${NGINX_PORT} default_server;
    server_name _;

    # Long proxy timeouts (24h) tolerate long-lived websocket sessions
    # Without these, idle WebSockets hit the default 60s timeout
    proxy_connect_timeout 86400s;
    proxy_send_timeout 86400s;
    proxy_read_timeout 86400s;
    send_timeout 86400s;

    # WebSocket upgrade support for the code-server remote terminal and editor
    proxy_http_version 1.1;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection upgrade;
    proxy_set_header X-Connection-Upgrade \$http_upgrade;

    # Forward client metadata so code-server can build absolute URLs correctly
    proxy_set_header Host \$http_host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto \$scheme;
    proxy_set_header Accept-Encoding gzip;

    # Disable buffering so interactive output (terminals, logs) flushes immediately
    proxy_buffering off;
    proxy_request_buffering off;

    location / {
        proxy_pass http://localhost:${INTERNAL_PORT}/;
    }

    # Allow drop-in location blocks (e.g. explorer-location.conf) without
    # touching this template.  Explorer and similar add-ons must write their
    # nginx snippets to /etc/nginx/conf.d/ instead of patching this file.
    include /etc/nginx/conf.d/*.conf;
}
EOF

# Enable the site by symlinking into sites-enabled
ln -sf /etc/nginx/sites-available/code-server /etc/nginx/sites-enabled/code-server

echo 'Configuration file created'

# ========================================
# Validate the configuration before restarting nginx
# ========================================

# Test nginx configuration syntax
echo 'Testing nginx configuration...'
nginx -t

# Check for duplicate server blocks that would bind the same port
echo 'Checking for duplicate configurations...'
CONF_COUNT=$(find /etc/nginx -name '*code-server*' -type f | wc -l)
echo "Found $CONF_COUNT code-server configuration file(s)"

if [ "$CONF_COUNT" -ne 1 ]; then
  echo '[WARNING] Multiple code-server configurations detected!'
  find /etc/nginx -name '*code-server*' -type f
fi

# Restart nginx to pick up the new configuration
systemctl restart nginx
systemctl enable nginx

# Confirm the service is active
sleep 2
if systemctl is-active --quiet nginx; then
  echo '[OK] nginx configured successfully with timeout and WebSocket support'
  echo 'No configuration conflicts detected'
else
  echo '[NG] nginx failed to start'
  systemctl status nginx --no-pager -l
  exit 1
fi
