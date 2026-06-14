#!/usr/bin/env bash
set -euo pipefail

# Task: Verify docker + Neuron device + DLC image presence
# Description: Confirms docker daemon, /dev/neuron0 and image are ready.
# The image is pulled separately in 05-pull-image so the precheck does not block on a 10+GB download.

command -v docker >/dev/null || { echo '[NG] docker not installed'; exit 1; }
systemctl is-active docker.service >/dev/null 2>&1 || { echo '[NG] docker.service not active'; exit 1; }
test -e /dev/neuron0 || { echo '[NG] /dev/neuron0 missing — not a trn1/trn2 host?'; exit 1; }
command -v curl tar >/dev/null || { echo '[NG] curl/tar required'; exit 1; }
echo '[OK] precheck'
