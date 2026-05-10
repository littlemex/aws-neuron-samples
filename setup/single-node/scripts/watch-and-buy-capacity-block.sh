#!/bin/bash
# Capacity Block pool monitoring + automatic purchase on condition match.
#
# Background (as of 2026-05-10):
#   - Existing CB cr-EXAMPLE1234567890 expires at 5/14 11:30Z
#   - A bridge CB covering 5/14 to 5/18 needs to be reserved in advance,
#     but the pool is exhausted and returning 0 results
#   - AWS CB API constraints:
#       * start-date-range can only be set up to "now + 48h"
#       * end-date-range can only be set up to "now + 9 days"
#       * A 5/14-start CB will not appear in the search window until after 5/12 11:30Z
#   - The pool changes over time as other tenants release CBs or AWS adds capacity,
#     so periodic polling is necessary
#
# How this script works:
#   - Runs describe-capacity-block-offerings every N minutes
#   - When an offering matching the conditions (duration >= MIN_HOURS,
#     start time constraint, end <= MAX_END_DATE, lowest cost) is found:
#       * If --auto-purchase is ON: purchases immediately -> saves to Parameter Store
#       * If --auto-purchase is OFF: notifies only (stdout + log file), prints manual purchase command
#
# Absolute rules:
#   - CB purchase is a financial commitment (upfront fee) -> default is dry-run;
#     use --auto-purchase to explicitly enable purchasing
#   - To prevent duplicate purchases, a state file (/tmp/cb-watch-state) stops the
#     script after a successful purchase
#
# Usage:
#   # Dry run (notify only, no purchase - default)
#   ./watch-and-buy-capacity-block.sh
#
#   # Auto purchase (buy as soon as a match is found)
#   AWS_PROFILE=<your-profile> ./watch-and-buy-capacity-block.sh --auto-purchase \
#       --min-hours 96 --target-start-after 2026-05-14T00:00:00Z --max-end 2026-05-19T12:00:00Z
#
#   # Single check (run once without looping)
#   ./watch-and-buy-capacity-block.sh --once
#
#   # Custom conditions
#   ./watch-and-buy-capacity-block.sh --instance-type trn2.3xlarge --interval 300 \
#       --min-hours 120 --target-start-after 2026-05-14T00:00:00Z --region sa-east-1

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ----- defaults -----
REGION="sa-east-1"
INSTANCE_TYPE="trn2.3xlarge"
INSTANCE_COUNT=1
MIN_HOURS=96                                  # Minimum duration in hours
TARGET_START_AFTER="2026-05-14T00:00:00Z"     # Offering must start on or after this time
MAX_END="2026-05-19T12:00:00Z"                # Offering must end on or before this time
INTERVAL_SECONDS=300                          # Poll every 5 minutes
AUTO_PURCHASE=false
ONCE=false
STATE_FILE="/tmp/cb-watch-state-$$"           # Per-PID state file to support concurrent runs
LOG_FILE=""                                   # Default: stdout + stderr only
SAVE_TO_PARAMSTORE=true                       # Whether to call SSM save-params after a successful purchase
PARAM_PREFIX="/capacity-block"

usage() {
    cat <<EOF
Capacity Block Monitoring + Auto-Purchase Script

Options:
    -r, --region REGION            AWS region (default: ${REGION})
    -t, --instance-type TYPE       Instance type (default: ${INSTANCE_TYPE})
    -c, --instance-count COUNT     Instance count (default: ${INSTANCE_COUNT})
    --min-hours HOURS              Minimum duration (default: ${MIN_HOURS})
    --target-start-after ISO       Offering start must be on or after this datetime (default: ${TARGET_START_AFTER})
    --max-end ISO                  Offering end must be on or before this datetime (default: ${MAX_END})
    --interval SECONDS             Monitoring interval in seconds (default: ${INTERVAL_SECONDS})
    --auto-purchase                Purchase immediately on match (default: dry-run)
    --once                         Run once and do not loop (default: false)
    --no-save-params               Do not save to Parameter Store after purchase
    --log-file FILE                Tee log output to this file
    -h, --help                     Show this help message
EOF
}

# ----- parse args -----
while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--region)              REGION="$2"; shift 2;;
        -t|--instance-type)       INSTANCE_TYPE="$2"; shift 2;;
        -c|--instance-count)      INSTANCE_COUNT="$2"; shift 2;;
        --min-hours)              MIN_HOURS="$2"; shift 2;;
        --target-start-after)     TARGET_START_AFTER="$2"; shift 2;;
        --max-end)                MAX_END="$2"; shift 2;;
        --interval)               INTERVAL_SECONDS="$2"; shift 2;;
        --auto-purchase)          AUTO_PURCHASE=true; shift;;
        --once)                   ONCE=true; shift;;
        --no-save-params)         SAVE_TO_PARAMSTORE=false; shift;;
        --log-file)               LOG_FILE="$2"; shift 2;;
        -h|--help)                usage; exit 0;;
        *) echo -e "${RED}Unknown option: $1${NC}"; usage; exit 1;;
    esac
done

log() {
    local msg="[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
    # Always write log to stderr (stdout is reserved for scan_once result JSON)
    if [[ -n "$LOG_FILE" ]]; then
        echo -e "$msg" | tee -a "$LOG_FILE" >&2
    else
        echo -e "$msg" >&2
    fi
}

log "${BLUE}=== Capacity Block Monitoring Script Starting ===${NC}"
log "Region:             $REGION"
log "Instance Type:      $INSTANCE_TYPE"
log "Instance Count:     $INSTANCE_COUNT"
log "Min Duration:       ${MIN_HOURS}h"
log "Target Start After: $TARGET_START_AFTER"
log "Max End:            $MAX_END"
log "Interval:           ${INTERVAL_SECONDS}s"
log "Auto Purchase:      $AUTO_PURCHASE"
log "Once:               $ONCE"
log "State File:         $STATE_FILE"
if [[ -n "$LOG_FILE" ]]; then log "Log File:           $LOG_FILE"; fi
log ""

# Duration candidates to search (valid values for trn2: 24,48,72,96,120,144,168h)
# Search from largest to smallest (to preferentially hit longer CBs)
SEARCH_DURATIONS="168 144 120 96 72 48 24"
# Filter out durations below MIN_HOURS
FILTERED_DURATIONS=""
for H in $SEARCH_DURATIONS; do
    if [ "$H" -ge "$MIN_HOURS" ]; then
        FILTERED_DURATIONS="$FILTERED_DURATIONS $H"
    fi
done
log "Try durations (desc): $FILTERED_DURATIONS"
log ""

# ----- one scan attempt -----
# Echo a matching offering as a single JSON line. Empty output if no match.
scan_once() {
    local hits_json="[]"
    for HOURS in $FILTERED_DURATIONS; do
        # Sleep to avoid rate limiting
        sleep 1
        local out err
        out=$(aws ec2 describe-capacity-block-offerings \
            --instance-type "$INSTANCE_TYPE" \
            --instance-count "$INSTANCE_COUNT" \
            --capacity-duration-hours "$HOURS" \
            --end-date-range "$MAX_END" \
            --all-availability-zones \
            --region "$REGION" \
            --no-paginate \
            --output json 2>/tmp/cb-watch-err-$$.txt) || true
        err=$(cat /tmp/cb-watch-err-$$.txt)
        rm -f /tmp/cb-watch-err-$$.txt

        if [[ -n "$err" ]]; then
            # InvalidParameterValue (end date not valid) and similar are fatal;
            # RequestLimitExceeded is transient and should be skipped
            if echo "$err" | grep -q "RequestLimitExceeded"; then
                log "${YELLOW}[scan] rate limited, sleeping 30s${NC}"
                sleep 30
                continue
            fi
            log "${YELLOW}[scan] dur=${HOURS}h ERR: $(echo "$err" | grep -oE 'An error [^.]+' | head -1)${NC}"
            continue
        fi

        # Filter by condition: StartDate >= TARGET_START_AFTER and EndDate <= MAX_END
        local filtered
        filtered=$(echo "$out" | jq -c --arg after "$TARGET_START_AFTER" --arg before "$MAX_END" \
            '.CapacityBlockOfferings[]
             | select(.StartDate >= $after and .EndDate <= $before)
             | {id:.CapacityBlockOfferingId, start:.StartDate, end:.EndDate,
                hours:.CapacityBlockDurationHours, az:.AvailabilityZone,
                price:.UpfrontFee, currency:.CurrencyCode, tenancy:.Tenancy}')

        if [[ -n "$filtered" ]]; then
            while IFS= read -r line; do
                log "${GREEN}[HIT] dur=${HOURS}h offering: $line${NC}"
            done <<< "$filtered"
            # Use the first matching offering (longer durations are searched first)
            local first
            first=$(echo "$filtered" | head -1)
            # Output result JSON to stdout only (log goes to stderr as configured above)
            echo "$first"
            return 0
        else
            log "  dur=${HOURS}h matching offerings: 0"
        fi
    done
    return 1
}

purchase_offering() {
    local offering_id="$1"
    local start_iso="$2"
    log ""
    log "${BLUE}[PURCHASE] attempting offering_id=$offering_id${NC}"
    local result
    result=$(aws ec2 purchase-capacity-block \
        --capacity-block-offering-id "$offering_id" \
        --instance-platform Linux/UNIX \
        --region "$REGION" \
        --output json 2>&1)
    if [ $? -ne 0 ]; then
        log "${RED}[PURCHASE] FAILED${NC}"
        log "$result"
        return 1
    fi
    local cr_id az
    cr_id=$(echo "$result" | jq -r '.CapacityReservation.CapacityReservationId')
    az=$(echo "$result" | jq -r '.CapacityReservation.AvailabilityZone')
    log "${GREEN}[PURCHASE] OK${NC}"
    log "  CapacityReservationId: $cr_id"
    log "  AZ:                    $az"
    log "  Start:                 $start_iso"

    # Save to Parameter Store
    if [[ "$SAVE_TO_PARAMSTORE" == true ]]; then
        log ""
        log "${BLUE}[PARAM] Saving to Parameter Store${NC}"
        aws ssm put-parameter \
            --name "${PARAM_PREFIX}/${REGION}/reservation-id-next" \
            --value "$cr_id" \
            --type String --overwrite \
            --region "$REGION" >/dev/null
        # Infer the default VPC subnet for the AZ
        local subnet
        subnet=$(aws ec2 describe-subnets \
            --region "$REGION" \
            --filters "Name=availability-zone,Values=$az" "Name=default-for-az,Values=true" \
            --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
        if [[ -n "$subnet" && "$subnet" != "None" ]]; then
            aws ssm put-parameter \
                --name "${PARAM_PREFIX}/${REGION}/subnet-id-next" \
                --value "$subnet" \
                --type String --overwrite \
                --region "$REGION" >/dev/null
            log "  Saved: ${PARAM_PREFIX}/${REGION}/reservation-id-next = $cr_id"
            log "  Saved: ${PARAM_PREFIX}/${REGION}/subnet-id-next      = $subnet"
            log ""
            log "${YELLOW}[NOTE] To switch to this CB after the current one expires, run:${NC}"
            log "  aws ssm put-parameter --name ${PARAM_PREFIX}/${REGION}/reservation-id \\"
            log "    --value $cr_id --type String --overwrite --region $REGION"
            log "  aws ssm put-parameter --name ${PARAM_PREFIX}/${REGION}/subnet-id \\"
            log "    --value $subnet --type String --overwrite --region $REGION"
        else
            log "${YELLOW}[WARN] Could not retrieve the default subnet for AZ $az. Manual save-params required.${NC}"
        fi
    fi
    # Output only the CR ID to stdout (all log output goes to stderr)
    echo "$cr_id"
    return 0
}

# ----- main loop -----
trap 'log "[INT] interrupted"; exit 130' INT TERM

ATTEMPT=0
while true; do
    ATTEMPT=$((ATTEMPT + 1))
    log "${BLUE}=== scan #${ATTEMPT} at $(date -u +%H:%M:%SZ) ===${NC}"
    HIT=$(scan_once || true)

    if [[ -n "$HIT" ]]; then
        log ""
        log "${GREEN}[MATCH] Found a matching offering:${NC}"
        log "$HIT"
        OFFERING_ID=$(echo "$HIT" | jq -r '.id')
        START=$(echo "$HIT" | jq -r '.start')

        if [[ "$AUTO_PURCHASE" == true ]]; then
            # Use state file to prevent duplicate purchases in the same session
            if [[ -f "$STATE_FILE" ]]; then
                log "${YELLOW}[SKIP] state file exists, already purchased once in this session${NC}"
                exit 0
            fi
            if CR_ID=$(purchase_offering "$OFFERING_ID" "$START"); then
                echo "$CR_ID" > "$STATE_FILE"
                log ""
                log "${GREEN}[DONE] purchase complete, exiting${NC}"
                exit 0
            else
                log "${RED}[PURCHASE FAILED] continuing to next scan${NC}"
            fi
        else
            log ""
            log "${YELLOW}[DRY-RUN] --auto-purchase not specified. To purchase manually:${NC}"
            log "  aws ec2 purchase-capacity-block --region $REGION \\"
            log "    --capacity-block-offering-id $OFFERING_ID \\"
            log "    --instance-platform Linux/UNIX"
            log ""
            if [[ "$ONCE" == true ]]; then
                exit 0
            fi
        fi
    else
        log "  no matching offerings this scan"
    fi

    if [[ "$ONCE" == true ]]; then
        log ""
        log "${BLUE}[DONE] --once specified, exiting (no match found)${NC}"
        exit 0
    fi

    log ""
    log "  next scan in ${INTERVAL_SECONDS}s..."
    sleep "$INTERVAL_SECONDS"
done
