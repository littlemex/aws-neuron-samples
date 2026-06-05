#!/bin/bash
# Capacity Block management script

set -e

# Color definitions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Show usage help
usage() {
    cat << EOF
Capacity Block Management Script

Usage: $0 [COMMAND] [OPTIONS]

Commands:
    search                               Search for available Capacity Blocks
    purchase                             Purchase a Capacity Block
    list                                 List purchased Capacity Blocks
    describe                             Show detailed information about a Capacity Block
    cancel                               Cancel a Capacity Block
    save-params                          Save parameters to Parameter Store (per --slot)
    load-params                          Load parameters from Parameter Store (per --slot)
    list-params                          List every Capacity Block slot stored in Parameter Store

Options:
    -r, --region REGION                  AWS region (no default; honours AWS_DEFAULT_REGION / AWS_REGION env vars)
    -t, --instance-type TYPE             Instance type (default: trn2.3xlarge)
    -c, --instance-count COUNT           Instance count (default: 1)
    -d, --duration HOURS                 Duration in hours (default: 1)
    --start-time TIME                    Start time (ISO8601 format, e.g. 2026-01-27T00:00:00Z)
    --offering-id ID                     Capacity Block Offering ID (required for purchase)
    --reservation-id ID                  Capacity Reservation ID (required for describe/cancel)
    --subnet-id ID                       Subnet ID (used with save-params)
    --slot NAME                          Named Parameter Store slot for save-params/load-params.
                                         Lets you keep multiple reservations side by side.
                                         Default: "default".
    -h, --help                           Show this help message

Examples:
    # Search for available Capacity Blocks
    $0 search -t trn2.3xlarge -d 1

    # Purchase a specific Offering
    $0 purchase --offering-id cbr-a1234567890abcdef --start-time 2026-01-27T00:00:00Z

    # List purchased Capacity Blocks
    $0 list

    # Show detailed information about a Capacity Block
    $0 describe --reservation-id cr-06670284d2d99ffea

    # Cancel a Capacity Block
    $0 cancel --reservation-id cr-06670284d2d99ffea

    # Save parameters to Parameter Store under a named slot
    $0 save-params --slot training-a \\
       --reservation-id cr-AAAAAAAA --subnet-id subnet-AAAAAAAA

    # Load parameters from Parameter Store
    $0 load-params --slot training-a

    # List every slot in the current region
    $0 list-params
EOF
}

# Default values. REGION must be set explicitly via -r/--region or via
# AWS_DEFAULT_REGION/AWS_REGION env vars; the previous sa-east-1 default
# silently sent capacity-block searches and PURCHASES to the wrong region.
COMMAND=""
REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-}}"
INSTANCE_TYPE="trn2.3xlarge"
INSTANCE_COUNT="1"
DURATION="1"
START_TIME=""
OFFERING_ID=""
RESERVATION_ID=""
SUBNET_ID=""
SLOT="default"

# Parameter Store key prefix
PARAM_PREFIX="/capacity-block"

# Resolve Parameter Store keys for a given slot. The legacy layout
# ("/capacity-block/<region>/reservation-id") is preserved for the
# default slot so existing deployments keep working without migration,
# while named slots live under ".../slots/<slot>/".
cb_param_path() {
    # $1 = region, $2 = slot, $3 = key ("reservation-id" | "subnet-id")
    local region="$1" slot="$2" key="$3"
    if [[ "$slot" == "default" ]]; then
        echo "${PARAM_PREFIX}/${region}/${key}"
    else
        echo "${PARAM_PREFIX}/${region}/slots/${slot}/${key}"
    fi
}

# Get command
if [[ $# -gt 0 ]] && [[ ! "$1" =~ ^- ]]; then
    COMMAND="$1"
    shift
fi

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -t|--instance-type)
            INSTANCE_TYPE="$2"
            shift 2
            ;;
        -c|--instance-count)
            INSTANCE_COUNT="$2"
            shift 2
            ;;
        -d|--duration)
            DURATION="$2"
            shift 2
            ;;
        --start-time)
            START_TIME="$2"
            shift 2
            ;;
        --offering-id)
            OFFERING_ID="$2"
            shift 2
            ;;
        --reservation-id)
            RESERVATION_ID="$2"
            shift 2
            ;;
        --subnet-id)
            SUBNET_ID="$2"
            shift 2
            ;;
        --slot)
            SLOT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

# Region is required for every subcommand because the API calls below all
# need it; fail fast rather than silently targeting the wrong region.
if [[ -z "$REGION" ]]; then
    echo -e "${RED}Error: AWS region is required (-r/--region or AWS_REGION/AWS_DEFAULT_REGION env var)${NC}"
    usage
    exit 1
fi

# Execute command
case "$COMMAND" in
    search)
        echo -e "${BLUE}=========================================${NC}"
        echo -e "${BLUE}Capacity Block Search${NC}"
        echo -e "${BLUE}=========================================${NC}"
        echo "Region:         $REGION"
        echo "Instance type:  $INSTANCE_TYPE"
        echo "Instance count: $INSTANCE_COUNT"
        echo "Duration:       ${DURATION} hours"
        if [[ -n "$START_TIME" ]]; then
            echo "Start time:     $START_TIME"
        fi
        echo -e "${BLUE}=========================================${NC}"
        echo ""

        # Build search parameters
        SEARCH_PARAMS=(
            --instance-type "$INSTANCE_TYPE"
            --instance-count "$INSTANCE_COUNT"
            --capacity-duration-hours "$DURATION"
            --region "$REGION"
        )

        # If start time is specified, calculate the end time
        if [[ -n "$START_TIME" ]]; then
            # Calculate end time (start time + duration)
            if command -v date &> /dev/null; then
                if date --version &> /dev/null 2>&1; then
                    # GNU date
                    END_TIME=$(date -u -d "$START_TIME + $DURATION hours" +"%Y-%m-%dT%H:%M:%SZ")
                else
                    # BSD date (macOS)
                    END_TIME=$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$START_TIME" -v+${DURATION}H +"%Y-%m-%dT%H:%M:%SZ")
                fi
                SEARCH_PARAMS+=(--start-date-range "$START_TIME" --end-date-range "$END_TIME")
            fi
        fi

        echo -e "${BLUE}🔍 Searching for available Capacity Blocks...${NC}"
        echo ""

        # Execute search
        OFFERINGS=$(aws ec2 describe-capacity-block-offerings "${SEARCH_PARAMS[@]}" --output json)

        # Display results
        OFFERING_COUNT=$(echo "$OFFERINGS" | jq '.CapacityBlockOfferings | length')

        if [[ "$OFFERING_COUNT" -eq 0 ]]; then
            echo -e "${YELLOW}⚠️  No available Capacity Blocks found${NC}"
            exit 0
        fi

        echo -e "${GREEN}✅ Found ${OFFERING_COUNT} Capacity Block(s)${NC}"
        echo ""

        # Display each offering
        echo "$OFFERINGS" | jq -r '.CapacityBlockOfferings[] |
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" +
            "Offering ID: \(.CapacityBlockOfferingId)\n" +
            "Start time: \(.StartDate)\n" +
            "End time: \(.EndDate)\n" +
            "Duration: \(.CapacityBlockDurationHours) hours\n" +
            "Availability Zone: \(.AvailabilityZone)\n" +
            "Instance type: \(.InstanceType)\n" +
            "Instance count: \(.InstanceCount)\n" +
            "Price: $\(.UpfrontFee) (\(.CurrencyCode))\n" +
            "Tenancy: \(.Tenancy)\n"'

        echo ""
        echo -e "${YELLOW}💡 To purchase:${NC}"
        echo "  $0 purchase --offering-id <OFFERING_ID> --start-time <START_TIME>"
        ;;

    purchase)
        if [[ -z "$OFFERING_ID" ]]; then
            echo -e "${RED}Error: --offering-id is required${NC}"
            usage
            exit 1
        fi

        if [[ -z "$START_TIME" ]]; then
            echo -e "${RED}Error: --start-time is required${NC}"
            usage
            exit 1
        fi

        echo -e "${BLUE}=========================================${NC}"
        echo -e "${BLUE}Capacity Block Purchase${NC}"
        echo -e "${BLUE}=========================================${NC}"
        echo "Offering ID: $OFFERING_ID"
        echo "Start time:  $START_TIME"
        echo "Region:      $REGION"
        echo -e "${BLUE}=========================================${NC}"
        echo ""

        echo -e "${YELLOW}⚠️  You are about to purchase a Capacity Block${NC}"
        read -p "Continue? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            echo "Cancelled"
            exit 0
        fi

        echo ""
        echo -e "${BLUE}💳 Processing purchase...${NC}"

        # Execute purchase
        RESULT=$(aws ec2 purchase-capacity-block \
            --capacity-block-offering-id "$OFFERING_ID" \
            --instance-platform Linux/UNIX \
            --region "$REGION" \
            --output json)

        CAPACITY_RESERVATION_ID=$(echo "$RESULT" | jq -r '.CapacityReservation.CapacityReservationId')
        AVAILABILITY_ZONE=$(echo "$RESULT" | jq -r '.CapacityReservation.AvailabilityZone')

        echo ""
        echo -e "${GREEN}✅ Capacity Block purchased successfully!${NC}"
        echo ""
        echo -e "${GREEN}📋 Purchase details:${NC}"
        echo "  Capacity Reservation ID: $CAPACITY_RESERVATION_ID"
        echo "  Availability Zone: $AVAILABILITY_ZONE"
        echo ""

        # Retrieve Subnet ID (first subnet in the same AZ)
        DETECTED_SUBNET_ID=$(aws ec2 describe-subnets \
            --region "$REGION" \
            --filters "Name=availability-zone,Values=$AVAILABILITY_ZONE" \
            --query 'Subnets[0].SubnetId' \
            --output text 2>/dev/null)

        if [[ -n "$DETECTED_SUBNET_ID" ]] && [[ "$DETECTED_SUBNET_ID" != "None" ]]; then
            echo "  Subnet ID (detected): $DETECTED_SUBNET_ID"
            echo ""
        fi

        # Prompt to save to Parameter Store
        echo -e "${YELLOW}💾 Save parameters to Parameter Store?${NC}"
        read -p "(yes/no): " -r
        if [[ $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            # Use the detected or specified Subnet ID
            SAVE_SUBNET_ID="${DETECTED_SUBNET_ID:-$SUBNET_ID}"

            if [[ -z "$SAVE_SUBNET_ID" ]]; then
                echo ""
                echo -e "${YELLOW}⚠️  Subnet ID not found. Please specify manually:${NC}"
                read -p "Subnet ID: " SAVE_SUBNET_ID
            fi

            # Save to Parameter Store under the selected slot.
            $0 save-params \
                --slot "$SLOT" \
                --reservation-id "$CAPACITY_RESERVATION_ID" \
                --subnet-id "$SAVE_SUBNET_ID" \
                -r "$REGION"
        fi

        echo ""
        echo -e "${YELLOW}💡 To view details:${NC}"
        echo "  $0 describe --reservation-id $CAPACITY_RESERVATION_ID"
        echo ""
        echo -e "${YELLOW}💡 To deploy:${NC}"
        echo "  cd $(dirname "$(dirname "$(realpath "$0")")")"
        echo "  bash scripts/deploy.sh --use-capacity-block -r $REGION"
        ;;

    list)
        echo -e "${BLUE}=========================================${NC}"
        echo -e "${BLUE}Purchased Capacity Block List${NC}"
        echo -e "${BLUE}=========================================${NC}"
        echo "Region: $REGION"
        echo -e "${BLUE}=========================================${NC}"
        echo ""

        # Retrieve list
        RESERVATIONS=$(aws ec2 describe-capacity-reservations \
            --region "$REGION" \
            --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
            --output json)

        RESERVATION_COUNT=$(echo "$RESERVATIONS" | jq '.CapacityReservations | length')

        if [[ "$RESERVATION_COUNT" -eq 0 ]]; then
            echo -e "${YELLOW}⚠️  No purchased Capacity Blocks found${NC}"
            exit 0
        fi

        echo -e "${GREEN}✅ Found ${RESERVATION_COUNT} Capacity Block(s)${NC}"
        echo ""

        # Display each reservation
        echo "$RESERVATIONS" | jq -r '.CapacityReservations[] |
            "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n" +
            "Reservation ID: \(.CapacityReservationId)\n" +
            "Status: \(.State)\n" +
            "Instance type: \(.InstanceType)\n" +
            "Total instances: \(.TotalInstanceCount)\n" +
            "Available instances: \(.AvailableInstanceCount)\n" +
            "Availability Zone: \(.AvailabilityZone)\n" +
            "Start time: \(.StartDate // "N/A")\n" +
            "End time: \(.EndDate // "N/A")\n" +
            "Created at: \(.CreateDate)\n"'

        echo ""
        echo -e "${YELLOW}💡 To view details:${NC}"
        echo "  $0 describe --reservation-id <RESERVATION_ID>"
        ;;

    describe)
        if [[ -z "$RESERVATION_ID" ]]; then
            echo -e "${RED}Error: --reservation-id is required${NC}"
            usage
            exit 1
        fi

        echo -e "${BLUE}=========================================${NC}"
        echo -e "${BLUE}Capacity Block Details${NC}"
        echo -e "${BLUE}=========================================${NC}"
        echo "Reservation ID: $RESERVATION_ID"
        echo "Region:         $REGION"
        echo -e "${BLUE}=========================================${NC}"
        echo ""

        # Retrieve details
        RESERVATION=$(aws ec2 describe-capacity-reservations \
            --capacity-reservation-ids "$RESERVATION_ID" \
            --region "$REGION" \
            --output json)

        RESERVATION_EXISTS=$(echo "$RESERVATION" | jq '.CapacityReservations | length')

        if [[ "$RESERVATION_EXISTS" -eq 0 ]]; then
            echo -e "${RED}❌ Capacity Reservation ID '$RESERVATION_ID' not found${NC}"
            exit 1
        fi

        # Display formatted JSON
        echo "$RESERVATION" | jq -r '.CapacityReservations[0] |
            "📋 Basic Information\n" +
            "  Reservation ID: \(.CapacityReservationId)\n" +
            "  ARN: \(.CapacityReservationArn)\n" +
            "  Status: \(.State)\n" +
            "  Type: \(.InstanceMatchCriteria)\n" +
            "\n" +
            "🖥️  Instance Information\n" +
            "  Instance type: \(.InstanceType)\n" +
            "  Platform: \(.InstancePlatform)\n" +
            "  Availability Zone: \(.AvailabilityZone)\n" +
            "  Tenancy: \(.Tenancy)\n" +
            "\n" +
            "📊 Capacity Information\n" +
            "  Total instances: \(.TotalInstanceCount)\n" +
            "  Available instances: \(.AvailableInstanceCount)\n" +
            "\n" +
            "📅 Schedule Information\n" +
            "  Created at: \(.CreateDate)\n" +
            "  Start time: \(.StartDate // "N/A")\n" +
            "  End time: \(.EndDate // "N/A")\n" +
            "  End type: \(.EndDateType)\n"'

        # Tags
        TAGS=$(echo "$RESERVATION" | jq -r '.CapacityReservations[0].Tags[]? | "  \(.Key): \(.Value)"')
        if [[ -n "$TAGS" ]]; then
            echo ""
            echo "🏷️  Tags"
            echo "$TAGS"
        fi

        echo ""
        ;;

    cancel)
        if [[ -z "$RESERVATION_ID" ]]; then
            echo -e "${RED}Error: --reservation-id is required${NC}"
            usage
            exit 1
        fi

        echo -e "${BLUE}=========================================${NC}"
        echo -e "${BLUE}Capacity Block Cancellation${NC}"
        echo -e "${BLUE}=========================================${NC}"
        echo "Reservation ID: $RESERVATION_ID"
        echo "Region:         $REGION"
        echo -e "${BLUE}=========================================${NC}"
        echo ""

        echo -e "${YELLOW}⚠️  You are about to cancel a Capacity Block${NC}"
        echo -e "${YELLOW}    Note: Cancellation fees may apply${NC}"
        read -p "Are you sure you want to cancel? (yes/no): " -r
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            echo "Cancellation aborted"
            exit 0
        fi

        echo ""
        echo -e "${BLUE}🗑️  Processing cancellation...${NC}"

        # Execute cancellation
        aws ec2 cancel-capacity-reservation \
            --capacity-reservation-id "$RESERVATION_ID" \
            --region "$REGION" \
            --output json > /dev/null

        echo ""
        echo -e "${GREEN}✅ Capacity Block cancelled successfully${NC}"
        ;;

    save-params)
        if [[ -z "$RESERVATION_ID" ]]; then
            echo -e "${RED}Error: --reservation-id is required${NC}"
            usage
            exit 1
        fi

        if [[ -z "$SUBNET_ID" ]]; then
            echo -e "${RED}Error: --subnet-id is required${NC}"
            usage
            exit 1
        fi

        SAVE_RES_PATH=$(cb_param_path "$REGION" "$SLOT" "reservation-id")
        SAVE_SUB_PATH=$(cb_param_path "$REGION" "$SLOT" "subnet-id")

        echo -e "${BLUE}=========================================${NC}"
        echo -e "${BLUE}Parameter Store Save${NC}"
        echo -e "${BLUE}=========================================${NC}"
        echo "Slot:           $SLOT"
        echo "Reservation ID: $RESERVATION_ID"
        echo "Subnet ID:      $SUBNET_ID"
        echo "Region:         $REGION"
        echo -e "${BLUE}=========================================${NC}"
        echo ""

        # Check for existing parameters in this slot
        EXISTING_RESERVATION=$(aws ssm get-parameter \
            --name "$SAVE_RES_PATH" \
            --region "$REGION" \
            --query 'Parameter.Value' \
            --output text 2>/dev/null)

        EXISTING_SUBNET=$(aws ssm get-parameter \
            --name "$SAVE_SUB_PATH" \
            --region "$REGION" \
            --query 'Parameter.Value' \
            --output text 2>/dev/null)

        if [[ -n "$EXISTING_RESERVATION" ]] || [[ -n "$EXISTING_SUBNET" ]]; then
            echo -e "${YELLOW}⚠️  Existing parameters found in slot '$SLOT':${NC}"
            if [[ -n "$EXISTING_RESERVATION" ]]; then
                echo "  Reservation ID: $EXISTING_RESERVATION"
            fi
            if [[ -n "$EXISTING_SUBNET" ]]; then
                echo "  Subnet ID: $EXISTING_SUBNET"
            fi
            echo ""
            echo -e "${YELLOW}Overwrite this slot? (use a different --slot NAME to keep it)${NC}"
            read -p "(yes/no): " -r
            if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
                echo "Cancelled"
                exit 0
            fi
            echo ""
        fi

        echo -e "${BLUE}💾 Saving to Parameter Store...${NC}"

        # Save Reservation ID
        aws ssm put-parameter \
            --name "$SAVE_RES_PATH" \
            --value "$RESERVATION_ID" \
            --type String \
            --region "$REGION" \
            --overwrite > /dev/null

        # Save Subnet ID
        aws ssm put-parameter \
            --name "$SAVE_SUB_PATH" \
            --value "$SUBNET_ID" \
            --type String \
            --region "$REGION" \
            --overwrite > /dev/null

        echo ""
        echo -e "${GREEN}✅ Parameters saved to slot '$SLOT'${NC}"
        echo ""
        echo "Saved parameters:"
        echo "  $SAVE_RES_PATH = $RESERVATION_ID"
        echo "  $SAVE_SUB_PATH = $SUBNET_ID"
        echo ""
        echo -e "${YELLOW}💡 To load:${NC}"
        echo "  $0 load-params --slot $SLOT -r $REGION"
        ;;

    load-params)
        LOAD_RES_PATH=$(cb_param_path "$REGION" "$SLOT" "reservation-id")
        LOAD_SUB_PATH=$(cb_param_path "$REGION" "$SLOT" "subnet-id")

        echo -e "${BLUE}=========================================${NC}"
        echo -e "${BLUE}Parameter Store Load${NC}"
        echo -e "${BLUE}=========================================${NC}"
        echo "Slot:   $SLOT"
        echo "Region: $REGION"
        echo -e "${BLUE}=========================================${NC}"
        echo ""

        # Load parameters
        LOADED_RESERVATION=$(aws ssm get-parameter \
            --name "$LOAD_RES_PATH" \
            --region "$REGION" \
            --query 'Parameter.Value' \
            --output text 2>/dev/null)

        LOADED_SUBNET=$(aws ssm get-parameter \
            --name "$LOAD_SUB_PATH" \
            --region "$REGION" \
            --query 'Parameter.Value' \
            --output text 2>/dev/null)

        if [[ -z "$LOADED_RESERVATION" ]] && [[ -z "$LOADED_SUBNET" ]]; then
            echo -e "${RED}❌ No parameters found in Parameter Store${NC}"
            echo ""
            echo "To save parameters:"
            echo "  $0 save-params --reservation-id <ID> --subnet-id <ID> -r $REGION"
            exit 1
        fi

        echo -e "${GREEN}✅ Parameters loaded from Parameter Store${NC}"
        echo ""
        echo "📋 Loaded parameters:"
        if [[ -n "$LOADED_RESERVATION" ]]; then
            echo "  Reservation ID: $LOADED_RESERVATION"
        else
            echo -e "  Reservation ID: ${YELLOW}not set${NC}"
        fi

        if [[ -n "$LOADED_SUBNET" ]]; then
            echo "  Subnet ID: $LOADED_SUBNET"
        else
            echo -e "  Subnet ID: ${YELLOW}not set${NC}"
        fi

        echo ""
        echo -e "${YELLOW}💡 Deploy command:${NC}"
        if [[ -n "$LOADED_RESERVATION" ]] && [[ -n "$LOADED_SUBNET" ]]; then
            echo "  cd $(dirname "$(dirname "$(realpath "$0")")")"
            if [[ "$SLOT" == "default" ]]; then
                echo "  bash scripts/deploy.sh --use-capacity-block -r $REGION"
            else
                echo "  bash scripts/deploy.sh --use-capacity-block --slot $SLOT -r $REGION"
            fi
        fi
        ;;

    list-params)
        echo -e "${BLUE}=========================================${NC}"
        echo -e "${BLUE}Parameter Store Slots${NC}"
        echo -e "${BLUE}=========================================${NC}"
        echo "Region: $REGION"
        echo -e "${BLUE}=========================================${NC}"
        echo ""

        # 1) Legacy default slot (pre-slots layout).
        LEGACY_RES=$(aws ssm get-parameter \
            --name "${PARAM_PREFIX}/${REGION}/reservation-id" \
            --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || true)
        LEGACY_SUB=$(aws ssm get-parameter \
            --name "${PARAM_PREFIX}/${REGION}/subnet-id" \
            --region "$REGION" --query 'Parameter.Value' --output text 2>/dev/null || true)
        if [[ -n "$LEGACY_RES" ]] || [[ -n "$LEGACY_SUB" ]]; then
            echo -e "${GREEN}[slot] default${NC}"
            echo "  reservation-id: ${LEGACY_RES:-unset}"
            echo "  subnet-id:      ${LEGACY_SUB:-unset}"
            echo ""
        fi

        # 2) Named slots under "${PARAM_PREFIX}/${REGION}/slots/".
        NAMED_SLOTS=$(aws ssm get-parameters-by-path \
            --path "${PARAM_PREFIX}/${REGION}/slots/" --recursive \
            --region "$REGION" \
            --query 'Parameters[].Name' --output text 2>/dev/null \
            | tr '\t' '\n' \
            | sed -nE "s|^${PARAM_PREFIX}/${REGION}/slots/([^/]+)/.*|\1|p" \
            | sort -u)

        if [[ -z "$NAMED_SLOTS" ]] && [[ -z "$LEGACY_RES" ]] && [[ -z "$LEGACY_SUB" ]]; then
            echo -e "${YELLOW}No Capacity Block slots found in ${PARAM_PREFIX}/${REGION}/${NC}"
            echo ""
            echo "Save one with:"
            echo "  $0 save-params --slot NAME --reservation-id <id> --subnet-id <id> -r $REGION"
            exit 0
        fi

        for name in $NAMED_SLOTS; do
            NS_RES_PATH=$(cb_param_path "$REGION" "$name" "reservation-id")
            NS_SUB_PATH=$(cb_param_path "$REGION" "$name" "subnet-id")
            NS_RES=$(aws ssm get-parameter --name "$NS_RES_PATH" --region "$REGION" \
                --query 'Parameter.Value' --output text 2>/dev/null || true)
            NS_SUB=$(aws ssm get-parameter --name "$NS_SUB_PATH" --region "$REGION" \
                --query 'Parameter.Value' --output text 2>/dev/null || true)
            echo -e "${GREEN}[slot] $name${NC}"
            echo "  reservation-id: ${NS_RES:-unset}"
            echo "  subnet-id:      ${NS_SUB:-unset}"
            echo ""
        done

        echo -e "${YELLOW}💡 Deploy with:${NC}"
        echo "  bash scripts/deploy.sh --use-capacity-block --slot NAME -r $REGION"
        ;;

    "")
        echo -e "${RED}Error: A command is required${NC}"
        echo ""
        usage
        exit 1
        ;;

    *)
        echo -e "${RED}Error: Unknown command: $COMMAND${NC}"
        echo ""
        usage
        exit 1
        ;;
esac
