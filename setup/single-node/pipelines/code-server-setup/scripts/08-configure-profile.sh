#!/usr/bin/env bash
set -euo pipefail

# Task: Configure user profile
# Configure the user shell profile with PATH and environment variables for Neuron tooling

echo '==> Configuring user profile'
# Set system environment
echo 'LANG=en_US.utf-8' >> /etc/environment
echo 'LC_ALL=en_US.UTF-8' >> /etc/environment

# Configure .bashrc — unquoted heredoc so ${USER} expands to the actual username.
cat >> "/home/${USER}/.bashrc" <<EOF

# Path configuration
PATH=\$PATH:/home/${USER}/.local/bin
export PATH

# Disable telemetry
export NEXT_TELEMETRY_DISABLED=1

# Custom prompt
export PS1='\[\033[01;32m\]\u:\[\033[01;34m\]\w\[\033[00m\]\$ '
EOF

# Create .hushlogin to suppress login messages
touch "/home/${USER}/.hushlogin"

chown -R "${USER}:${USER}" "/home/${USER}"
echo 'User profile configured'
