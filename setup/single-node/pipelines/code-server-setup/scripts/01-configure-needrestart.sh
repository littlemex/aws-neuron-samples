#!/usr/bin/env bash
set -euo pipefail

# Task: Configure needrestart
# Configure needrestart to auto-restart services non-interactively during apt upgrades

echo '==> Configuring needrestart settings'
dpkg --configure -a || true
if [ -f /etc/needrestart/needrestart.conf ]; then
  sed -i 's/#$nrconf{kernelhints} = -1;/$nrconf{kernelhints} = 0;/' /etc/needrestart/needrestart.conf
  sed -i 's/#$nrconf{verbosity} = 2;/$nrconf{verbosity} = 0;/' /etc/needrestart/needrestart.conf
  sed -i "s/#\$nrconf{restart} = 'i';/\$nrconf{restart} = 'a';/" /etc/needrestart/needrestart.conf
  echo 'needrestart configuration updated'
else
  echo 'needrestart not found, skipping...'
fi
