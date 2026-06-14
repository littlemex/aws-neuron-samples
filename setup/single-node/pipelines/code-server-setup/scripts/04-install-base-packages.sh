#!/usr/bin/env bash
set -euo pipefail

# Task: Install base packages
# Install base packages (nginx, curl, jq, git, build-essential, python3-pip, etc.)

echo '==> Installing base packages'
dpkg --configure -a || true
apt-get -q update
DEBIAN_FRONTEND=noninteractive apt-get install -y -q curl gnupg whois argon2 unzip nginx openssl locales locales-all apt-transport-https ca-certificates software-properties-common python3-pip nodejs npm graphviz jq
echo 'Base packages installed successfully'
