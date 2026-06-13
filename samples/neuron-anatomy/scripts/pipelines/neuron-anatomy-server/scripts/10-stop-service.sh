#!/usr/bin/env bash
set -euo pipefail

# Task: 10-stop-service
# Name: Stop existing neuron-anatomy.service (if any)
# Description: Idempotent: ignore failures.

systemctl stop neuron-anatomy.service 2>/dev/null || true
echo '[OK] stop attempted'
