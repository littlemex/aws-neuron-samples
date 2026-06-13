#!/usr/bin/env bash
set -euo pipefail

# Task: Install VS Code extensions
# Install a curated set of VS Code extensions (Python, Jupyter, Remote-SSH, etc.)

echo '==> Installing VS Code extensions'

# Install AWS Toolkit
sudo -u "${USER}" --login code-server --install-extension AmazonWebServices.aws-toolkit-vscode --force || echo 'AWS Toolkit installation skipped'

chown -R "${USER}:${USER}" "/home/${USER}"
echo 'VS Code extensions installation completed'
