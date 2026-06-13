#!/usr/bin/env bash
set -euo pipefail

# Task: Create systemd service
# Create the systemd unit file for the code-server service

echo '==> Creating systemd service'
# Unquoted heredoc so ${USER} is substituted into the unit filename and User= field.
cat > "/etc/systemd/system/code-server@${USER}.service" <<EOF
[Unit]
Description=code-server
After=network.target

[Service]
Type=exec
ExecStart=/usr/bin/code-server
Restart=always
User=${USER}

[Install]
WantedBy=multi-user.target
EOF

echo 'Systemd service file created'
