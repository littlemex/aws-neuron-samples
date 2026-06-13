#!/usr/bin/env bash
set -euo pipefail

# Task: Cleanup old Neuron repository
# Remove stale Neuron apt repositories that can cause dpkg conflicts on fresh DLAMI boots

echo '==> Cleaning up old Neuron repository'
rm -f /etc/apt/sources.list.d/neuron.list
echo 'Cleanup completed'
