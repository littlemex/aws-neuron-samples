#!/usr/bin/env bash
set -euo pipefail

# Task: Pull DLC image if missing
# Description: docker pull is idempotent and resumes incomplete layers.
# Image is ~10GB and may take 5-10 min on first pull from public ECR.

if docker image inspect "${DLC_IMAGE}" >/dev/null 2>&1; then
  echo '[OK] image already present'
  exit 0
fi

echo "[INFO] pulling ${DLC_IMAGE}"
docker pull "${DLC_IMAGE}" 2>&1 | tail -10
docker image inspect "${DLC_IMAGE}" >/dev/null
