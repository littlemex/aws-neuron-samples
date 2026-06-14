#!/usr/bin/env bash
set -euo pipefail

# Task: mkdir canonical parent dirs
# symlink を貼る親ディレクトリ (/opt, /opt/dlami/nvme, /mnt/local) が無い trn2 用に空に作る。

mkdir -p /models
mkdir -p /opt
mkdir -p /opt/dlami/nvme
mkdir -p /mnt/local
echo '[OK] parent dirs ensured'
