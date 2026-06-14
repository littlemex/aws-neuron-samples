#!/usr/bin/env bash
set -euo pipefail

# Task: 60-health-check
# Name: Local HTTP health check on 127.0.0.1:${ANATOMY_PORT}/health and /neuron/topology
# Description: Wait up to 30s for /health to return 200, then verify that
#              /neuron/topology returns at least one chip so neuron-ls is
#              usable from the service user.
#
# The retry loop in the original JSON was 30 iterations with sleep 1.
# The runner's retries:30 + retry_delay:1s in the YAML replaces that outer
# loop; this script does a single attempt so one retry = one second delay.

code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ANATOMY_PORT}/health" || echo 000)
if [ "${code}" != "200" ]; then
  echo "[NG] /health returned http=${code}" >&2
  systemctl status neuron-anatomy.service --no-pager || true
  journalctl -u neuron-anatomy.service -n 80 --no-pager || true
  exit 1
fi
echo "[OK] health http=${code}"

topo=$(curl -sS "http://127.0.0.1:${ANATOMY_PORT}/neuron/topology")
echo "${topo}" | head -c 400; echo
chips=$(echo "${topo}" | python3 -c 'import sys, json; d=json.load(sys.stdin); print(d.get("neuron_device_count", 0))')
if [ "${chips:-0}" -lt 1 ]; then echo '[NG] /neuron/topology reported 0 chips' >&2; exit 1; fi
echo "[OK] topology: ${chips} chips"
