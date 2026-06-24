#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Unified model-server health-check (identical body in all *-server pipelines)
# =============================================================================
# The pipeline-runner sends ONLY this single script body to the host and injects
# every YAML `vars:` entry as an exported env var. It cannot source a shared
# helper, so the SAME logic is inlined verbatim into each server's health-check
# and parameterised purely by env vars:
#
#   PORT                   (required) TCP port /health listens on (127.0.0.1)
#   HEALTH_UNIT            (required) systemd unit name, e.g. "qwen3-vl.service"
#   HEALTH_BUDGET_SECONDS (required) how long a legitimate cold start may take
#                          for THIS model; the single source of truth for the
#                          wait budget (set per-server in the YAML vars, sized
#                          to match each model's worst-case load on EFS).
#   DOCKER_NAME           (optional) docker container name. Set ONLY for
#                          docker-backed units (xttsv2); enables `docker logs`
#                          in the failure dump.
#
# WHY A SEPARATE READINESS GATE
# -----------------------------
# These units are Type=simple: systemd reports the service "active" the instant
# ExecStart forks, which happens long before the model weights + NEFF are loaded
# onto the NeuronCores. So `systemctl is-active` == active does NOT mean "ready
# to serve". The only authoritative readiness signal is HTTP 200 on /health,
# which the server can only answer once it is listening (most servers bind the
# port only after the blocking model load completes).
#
# THREE STATES WE DISTINGUISH (the point of this rewrite)
# -------------------------------------------------------
#   * READY        : http==200            -> exit 0.
#   * STILL-LOADING: http==000 (connection refused, not listening yet) OR any
#                    other non-200 -> the model is still warming up. This is
#                    EXPECTED for many minutes on a large model loaded from EFS;
#                    keep waiting (up to HEALTH_BUDGET_SECONDS). Previously
#                    http==000 was collapsed into the same bucket as a hard
#                    failure, which made a slow-but-healthy load indistinguishable
#                    from a dead server and caused spurious deploy failures.
#   * BROKEN/DEAD  : detected WITHOUT waiting out the whole budget, via two
#                    fast-fail signals checked every poll:
#                      (a) `systemctl is-active` == "failed" — the main process
#                          exited and systemd gave up.
#                      (b) NRestarts increased beyond a small margin over the
#                          value sampled at start — the unit is crash-looping
#                          (Restart=always keeps respawning a process that dies).
#                          A growing restart count while /health never returns
#                          200 means broken, not loading.
#
# WHY AN EXPLICIT PER-SERVER BUDGET (not auto-derived from systemd)
# ----------------------------------------------------------------
# An earlier design tried to read the unit's TimeoutStartSec via `systemctl
# show`. That is unsafe: systemd exposes the start timeout only as the
# microsecond property TimeoutStartUSec, so `-p TimeoutStartSec` returns empty
# and the budget silently collapses to a default — false-failing exactly the
# slow loads this check must tolerate. Instead each server states its own budget
# in the YAML vars (HEALTH_BUDGET_SECONDS), kept >= that model's real worst-case
# load time, and the YAML step `timeout:` is set comfortably above it so the
# runner watchdog never kills us before our own budget elapses.
# =============================================================================

: "${PORT:?PORT must be injected from YAML vars}"
: "${HEALTH_UNIT:?HEALTH_UNIT must be injected from YAML vars}"
: "${HEALTH_BUDGET_SECONDS:?HEALTH_BUDGET_SECONDS must be injected from YAML vars}"
DOCKER_NAME="${DOCKER_NAME:-}"   # optional; empty for non-docker units

HEALTH_URL="http://127.0.0.1:${PORT}/health"

SLEEP_MIN=2        # poll tightly at first so a cache-hit fast start is caught quickly
SLEEP_MAX=15       # cap backoff so we never sleep through a late readiness flip
MAX_CRASH_RESTARTS=3   # restarts beyond baseline that prove a crash loop (not a slow load)

restarts_now() {
  # NRestarts = automatic restarts systemd has performed. Absent/unparseable
  # -> treat as 0 so we never crash-loop-fail spuriously.
  local v
  v="$(systemctl show "$HEALTH_UNIT" -p NRestarts --value 2>/dev/null || true)"
  case "$v" in
    ''|*[!0-9]*) echo 0 ;;
    *) echo "$v" ;;
  esac
}

dump_diag() {
  echo "[NG] ${HEALTH_UNIT} did not become healthy in ${HEALTH_BUDGET_SECONDS}s (last http=${1:-?})" >&2
  systemctl status "$HEALTH_UNIT" --no-pager || true
  journalctl -u "$HEALTH_UNIT" -n 200 --no-pager || true
  [ -n "$DOCKER_NAME" ] && docker logs "$DOCKER_NAME" --tail 200 2>&1 || true
}

baseline_restarts="$(restarts_now)"
start_ts="$(date +%s)"
sleep_s="$SLEEP_MIN"
code=000

while :; do
  code=$(curl -s -o /dev/null -w '%{http_code}' "$HEALTH_URL" 2>/dev/null || echo 000)
  if [ "$code" = "200" ]; then
    echo "[OK] ${HEALTH_UNIT} healthy (http=200)"
    curl -s "$HEALTH_URL" || true
    echo
    exit 0
  fi

  # --- fast-fail: process gave up entirely ---
  active="$(systemctl is-active "$HEALTH_UNIT" 2>/dev/null || true)"
  if [ "$active" = "failed" ]; then
    dump_diag "$code"
    echo "[NG] ${HEALTH_UNIT} is in 'failed' state — broken, not loading" >&2
    exit 1
  fi

  # --- fast-fail: crash loop (restart count climbing while never ready) ---
  cur_restarts="$(restarts_now)"
  if [ "$cur_restarts" -gt "$(( baseline_restarts + MAX_CRASH_RESTARTS ))" ]; then
    dump_diag "$code"
    echo "[NG] ${HEALTH_UNIT} crash-looping (NRestarts ${baseline_restarts} -> ${cur_restarts}) — broken" >&2
    exit 1
  fi

  # --- budget: still loading is fine, but only up to the per-model budget ---
  now_ts="$(date +%s)"
  if [ "$(( now_ts - start_ts ))" -ge "$HEALTH_BUDGET_SECONDS" ]; then
    dump_diag "$code"
    exit 1
  fi

  sleep "$sleep_s"
  sleep_s=$(( sleep_s * 2 ))
  [ "$sleep_s" -gt "$SLEEP_MAX" ] && sleep_s="$SLEEP_MAX"
done
