#!/usr/bin/env bash
set -euo pipefail

# Task: Create home directory
# Create the home directory and set ownership

echo "==> Creating home directory: ${HOME_DIR}"
mkdir -p "${HOME_DIR}"
mkdir -p "/home/${USER}/.local/bin"
chown -R "${USER}:${USER}" "/home/${USER}"
chown -R "${USER}:${USER}" "${HOME_DIR}"
echo 'Home directory ready'
