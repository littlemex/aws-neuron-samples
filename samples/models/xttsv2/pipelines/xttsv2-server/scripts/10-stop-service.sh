#!/usr/bin/env bash
set -euo pipefail

# Task: Stop existing xttsv2-server.service (if any)
# Idempotent: ignore failures and remove any stale container with the same name.

systemctl stop xttsv2-server.service 2>/dev/null || true
docker rm -f xttsv2-server 2>/dev/null || true
echo '[OK] stop attempted'
