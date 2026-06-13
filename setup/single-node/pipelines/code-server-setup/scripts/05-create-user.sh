#!/usr/bin/env bash
set -euo pipefail

# Task: Create user account
# Create a dedicated Linux user account to run code-server

echo "==> Creating user: ${USER}"
dpkg --configure -a || true
if [ "${USER}" = 'ubuntu' ]; then
  echo "Using existing user: ${USER}"
else
  if id "${USER}" >/dev/null 2>&1; then
    echo "User ${USER} already exists"
  else
    adduser --disabled-password --gecos '' "${USER}"
    echo "User ${USER} created successfully"
  fi
  # Set password if provided
  if [ -n "${PASSWORD}" ]; then
    echo "${USER}:${PASSWORD}" | chpasswd
    echo "Password set for user ${USER}"
  fi
  # Add to sudo group
  usermod -aG sudo "${USER}"
  echo "User ${USER} added to sudo group"
fi
getent passwd "${USER}"
