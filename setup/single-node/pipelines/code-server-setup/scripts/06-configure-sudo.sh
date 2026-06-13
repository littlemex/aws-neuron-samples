#!/usr/bin/env bash
set -euo pipefail

# Task: Configure sudo access
# Grant the code-server user passwordless sudo (disable for stricter deployments)

echo "==> Configuring sudo access for ${USER}"
# Use an unquoted heredoc so ${USER} expands to the actual username in the sudoers file.
cat > /etc/sudoers.d/91-vscode-user <<EOF
${USER} ALL=(ALL) NOPASSWD:ALL
EOF
chmod 0440 /etc/sudoers.d/91-vscode-user
echo 'Sudo configuration completed'
