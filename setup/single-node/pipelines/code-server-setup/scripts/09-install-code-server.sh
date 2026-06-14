#!/usr/bin/env bash
set -euo pipefail

# Task: Install Code Server
# Install code-server (the self-hosted VS Code server)

echo '==> Installing Code Server'
if [ -f /usr/bin/code-server ] || command -v code-server >/dev/null 2>&1; then
  echo 'Code Server is already installed'
  /usr/bin/code-server --version || code-server --version
else
  echo 'Installing Code Server...'
  export HOME=/root
  curl -fsSL https://code-server.dev/install.sh | sh 2>&1
  echo 'Code Server installed successfully'
  /usr/bin/code-server --version
fi
