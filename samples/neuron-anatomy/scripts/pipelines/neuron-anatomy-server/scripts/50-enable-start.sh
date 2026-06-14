#!/usr/bin/env bash
set -euo pipefail

# Task: 50-enable-start
# Name: daemon-reload + enable + start
# Description: systemctl daemon-reload, enable neuron-anatomy.service, and (re)start it.

systemctl daemon-reload
systemctl enable neuron-anatomy.service
systemctl restart neuron-anatomy.service
echo '[OK] service started'
