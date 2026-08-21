#!/usr/bin/env bash
# Sanity-checks every script in this directory without a NeuronCore, a real
# checkpoint, or a serving endpoint. Intended to catch bit-rot (syntax errors,
# broken imports, renamed flags) on a laptop or CI runner that has none of the
# real target hardware or software stack.
#
# What this does and does not prove:
#   - Every .py file parses as valid Python (ast.parse).
#   - probes.py, chunked_ssd_component.py, and moe_router_component.py have no
#     Neuron/torch_neuronx/transformers dependency for their CPU-only paths, so
#     --dry-run on those exercises real code (network calls / device tracing
#     skipped, everything else runs).
#   - version_isolation_trace.py and plugin_flags_trace.py depend on
#     transformers' nemotron_h model support (transformers==5.9.0 in this
#     investigation); on a host without that exact version, --dry-run reports
#     the missing dependency as a NOTE and still exits 0, since building the
#     full checkpoint is not the point of a syntax/structure smoke test.
#   - This script proves NOTHING about numerical correctness on real
#     hardware. It is a "did I break the script" check, not a reproduction.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

fail=0

echo "== syntax check =="
for f in *.py; do
  if python3 -c "import ast; ast.parse(open('${f}').read())"; then
    echo "  OK    ${f}"
  else
    echo "  FAIL  ${f}"
    fail=1
  fi
done

echo
echo "== probes.py --dry-run =="
if python3 probes.py --dry-run > /tmp/probes_dry_run.out 2>&1; then
  tail -n 3 /tmp/probes_dry_run.out
  echo "  OK"
else
  cat /tmp/probes_dry_run.out
  echo "  FAIL"
  fail=1
fi

echo
echo "== chunked_ssd_component.py --dry-run =="
if python3 chunked_ssd_component.py --dry-run > /tmp/ssd_dry_run.out 2>&1; then
  tail -n 4 /tmp/ssd_dry_run.out
  echo "  OK"
else
  cat /tmp/ssd_dry_run.out
  echo "  FAIL"
  fail=1
fi

echo
echo "== moe_router_component.py --dry-run =="
if python3 moe_router_component.py --dry-run > /tmp/moe_dry_run.out 2>&1; then
  tail -n 4 /tmp/moe_dry_run.out
  echo "  OK"
else
  cat /tmp/moe_dry_run.out
  echo "  FAIL"
  fail=1
fi

echo
echo "== version_isolation_trace.py --dry-run =="
if python3 version_isolation_trace.py --dry-run > /tmp/version_dry_run.out 2>&1; then
  tail -n 4 /tmp/version_dry_run.out
  echo "  OK"
else
  cat /tmp/version_dry_run.out
  echo "  FAIL"
  fail=1
fi

echo
echo "== plugin_flags_trace.py --dry-run =="
if python3 plugin_flags_trace.py --dry-run > /tmp/flags_dry_run.out 2>&1; then
  tail -n 4 /tmp/flags_dry_run.out
  echo "  OK"
else
  cat /tmp/flags_dry_run.out
  echo "  FAIL"
  fail=1
fi

echo
if [ "${fail}" -eq 0 ]; then
  echo "ALL DRY RUNS PASSED"
else
  echo "SOME DRY RUNS FAILED"
fi
exit "${fail}"
