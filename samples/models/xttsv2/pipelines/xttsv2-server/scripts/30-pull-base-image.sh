#!/usr/bin/env bash
set -euo pipefail

# Task: Pull DLC base image if missing
# Idempotent docker pull for the DLC layer that Dockerfile.server is built FROM.

if docker image inspect "${DLC_IMAGE}" >/dev/null 2>&1; then
  echo '[OK] base image already present'
  exit 0
fi
docker pull "${DLC_IMAGE}" 2>&1 | tail -10
