#!/usr/bin/env bash
set -euo pipefail

# Task: Verify /mnt/efs is mounted
# EFS がマウントされていなかったら setup-persistence.sh が先に走っていない、もしくは EFS 側 policy が壊れている。
# 後段の rsync/symlink で root fs を圧迫しないために必ず止める。

mountpoint -q /mnt/efs || { echo '[NG] /mnt/efs is not a mountpoint - run setup-persistence.sh first'; exit 1; }
df -hT /mnt/efs | tail -1
echo '[OK] /mnt/efs mounted'
