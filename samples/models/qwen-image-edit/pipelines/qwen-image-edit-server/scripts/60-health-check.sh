#!/usr/bin/env bash
set -euo pipefail

# Task: 60-health-check
# Description: compile cache 適用後でも model load + Neuron load で 5-10 min。 最大 1500s 待つ。
#              runner が retries:150 + retry_delay:10s で繰り返すため、このスクリプトは1回だけ試す。

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/health" || echo 000)
if [ "$code" = "200" ]; then
  echo "[OK] http=$code"
  curl -s "http://127.0.0.1:${PORT}/health"
  echo
  exit 0
fi

echo "[NG] health check returned http=$code" >&2
systemctl status qwen-image-edit.service --no-pager || true
journalctl -u qwen-image-edit.service -n 200 --no-pager || true
exit 1
