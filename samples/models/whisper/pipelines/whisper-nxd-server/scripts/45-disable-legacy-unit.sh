#!/usr/bin/env bash
set -euo pipefail

# タスク説明 (原文):
# torch_neuronx.trace 経路の whisper-server.service を残しておくと
# port 競合するので disable する。

systemctl disable whisper-server.service 2>/dev/null || true
echo "[OK] legacy unit disabled (if any)"
