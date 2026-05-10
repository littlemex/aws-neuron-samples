#!/bin/bash
# Capacity Block availability monitoring script
#
# Background: The AWS Capacity Block API's start-date-range filter only accepts
#       values within the next 48 hours, so the visible search window rolls forward
#       as time progresses. This script polls the API at a configurable interval
#       and prints matches (optionally firing a notifier hook). Useful when a
#       desired combination of instance type / duration / region is not currently
#       available and you want to catch it as capacity is returned to the pool.
#
# Usage:
#   1) Specify desired conditions (list of duration hour candidates, AZ, minimum duration, etc.)
#   2) Retry at the configured polling interval
#   3) Print results when a hit is found (+ run an optional notifier command)
#   4) Does NOT auto-purchase (that is a financial commitment and must be done manually)
#
# Examples:
#   # Single search (print hit/miss and exit)
#   ./scripts/watch-capacity-block.sh --once
#
#   # Continuous monitoring (15-minute interval, stop with Ctrl+C)
#   ./scripts/watch-capacity-block.sh --interval 900
#
#   # Specify conditions (duration >= 72h, run a hook on hit)
#   ./scripts/watch-capacity-block.sh --interval 900 \
#     --min-hours 72 \
#     --hook 'osascript -e "display notification \"CB HIT\" with title \"\""'
#
# Environment variables:
#   AWS_PROFILE    aws CLI profile (defaults to "default" if unset)
#   INSTANCE_TYPE  default: trn2.3xlarge
#   REGION         default: sa-east-1

set -u

INSTANCE_TYPE="${INSTANCE_TYPE:-trn2.3xlarge}"
INSTANCE_COUNT="1"
REGION="${REGION:-sa-east-1}"
# Duration candidates to search, from largest to smallest. CB is in 24h increments (24/48/72/96/120/144/168h).
DURATIONS=(168 144 120 96 72 48 24)
MIN_HOURS=24
INTERVAL=900   # 15 min
ONCE=false
HOOK=""

usage() {
    cat << EOF
Capacity Block Availability Monitoring Script

Options:
    -r, --region REGION         AWS region (default: sa-east-1)
    -t, --instance-type TYPE    default: trn2.3xlarge
    -c, --instance-count N      default: 1
    --min-hours N               Only consider durations >= this value (default: 24)
    --interval SEC              Polling interval in seconds (default: 900 = 15 min)
    --once                      Run a single search and exit
    --hook 'COMMAND'            Shell command to run on a hit (CB_* env vars are injected with results)
    -h, --help                  Show this help message

Environment variables:
    AWS_PROFILE                 aws CLI profile

Examples:
    $0 --once
    $0 --interval 900 --min-hours 72
    $0 --interval 600 --hook 'osascript -e "display notification \\"CB HIT\\""'
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--region) REGION="$2"; shift 2 ;;
        -t|--instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        -c|--instance-count) INSTANCE_COUNT="$2"; shift 2 ;;
        --min-hours) MIN_HOURS="$2"; shift 2 ;;
        --interval) INTERVAL="$2"; shift 2 ;;
        --once) ONCE=true; shift ;;
        --hook) HOOK="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1"; usage; exit 1 ;;
    esac
done

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

search_once() {
    local found=0
    for HOURS in "${DURATIONS[@]}"; do
        if [[ "$HOURS" -lt "$MIN_HOURS" ]]; then
            continue
        fi
        # The AWS CB API only accepts start-date-range up to "current time + 48h".
        # Omitting the date range means "all periods", and the API returns offerings
        # that exist within the current time + 48h window.
        local out
        out=$(aws ec2 describe-capacity-block-offerings \
            --instance-type "$INSTANCE_TYPE" \
            --instance-count "$INSTANCE_COUNT" \
            --capacity-duration-hours "$HOURS" \
            --all-availability-zones \
            --region "$REGION" \
            --output json 2>&1)
        local rc=$?
        if [[ $rc -ne 0 ]]; then
            # Handle rate limiting and other errors gracefully
            if echo "$out" | grep -q "RequestLimitExceeded"; then
                log "  dur=${HOURS}h: rate limited, sleep 30s"
                sleep 30
                continue
            fi
            log "  dur=${HOURS}h: ERROR $(echo "$out" | head -1)"
            continue
        fi
        local count
        count=$(echo "$out" | python3 -c 'import json,sys; print(len(json.load(sys.stdin).get("CapacityBlockOfferings",[])))')
        if [[ "$count" -gt 0 ]]; then
            log "HIT dur=${HOURS}h count=${count}"
            echo "$out" | python3 -c '
import json, sys
d = json.load(sys.stdin)
for o in d.get("CapacityBlockOfferings", []):
    print("  id=" + o.get("CapacityBlockOfferingId","?") +
          " start=" + o.get("StartDate","?") +
          " end=" + o.get("EndDate","?") +
          " hours=" + str(o.get("CapacityBlockDurationHours","?")) +
          " az=" + o.get("AvailabilityZone","?") +
          " price=" + str(o.get("UpfrontFee","?")) +
          " " + o.get("CurrencyCode","?") +
          " count=" + str(o.get("InstanceCount","?")))
'
            found=$count
            # Fire the hook (once per bucket hit, not per offering)
            if [[ -n "$HOOK" ]]; then
                # Pass the first offering via env vars
                local first
                first=$(echo "$out" | python3 -c 'import json,sys; o=json.load(sys.stdin)["CapacityBlockOfferings"][0]; print(o["CapacityBlockOfferingId"],o["StartDate"],o["EndDate"],o.get("AvailabilityZone",""),o.get("UpfrontFee",""))')
                local CB_ID CB_START CB_END CB_AZ CB_PRICE
                read -r CB_ID CB_START CB_END CB_AZ CB_PRICE <<< "$first"
                CB_HOURS="$HOURS" CB_ID="$CB_ID" CB_START="$CB_START" CB_END="$CB_END" \
                    CB_AZ="$CB_AZ" CB_PRICE="$CB_PRICE" \
                    bash -c "$HOOK" || log "  hook failed (rc=$?)"
            fi
        else
            log "  dur=${HOURS}h: 0"
        fi
        # Sleep to avoid rate limiting
        sleep 2
    done
    return $found
}

log "start: instance_type=${INSTANCE_TYPE} region=${REGION} min_hours=${MIN_HOURS} interval=${INTERVAL}s once=${ONCE}"

while true; do
    log "---- polling cycle ----"
    search_once || true
    if [[ "$ONCE" == true ]]; then
        break
    fi
    log "sleeping ${INTERVAL}s..."
    sleep "$INTERVAL"
done
