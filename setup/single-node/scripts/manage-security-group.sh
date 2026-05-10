#!/bin/bash

# Security group management script
# Add, remove, and list IP addresses in a security group

set -euo pipefail

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default values
REGION="sa-east-1"
STACK_NAME="neuron-code-server"
PORT=80
PROTOCOL="tcp"
DESCRIPTION=""

# Usage help
usage() {
    cat <<EOF
Security Group Management Script

Usage: $0 <COMMAND> [OPTIONS]

Commands:
    add         Add an IP address
    remove      Remove an IP address
    list        List current rules
    show-id     Show the security group ID

Options:
    -i, --ip IP              IP address (CIDR notation, e.g. 106.72.10.225/32)
    -r, --region REGION      AWS region (default: sa-east-1)
    -s, --stack-name NAME    Stack name (default: neuron-code-server)
    -g, --group-id ID        Security group ID (can be omitted if auto-detected)
    -p, --port PORT          Port number (default: 80)
    --protocol PROTOCOL      Protocol (default: tcp)
    -d, --description DESC   Rule description
    -h, --help               Show this help message

Examples:
    # Add an IP address
    $0 add -i 106.72.10.225/32 -r sa-east-1

    # Remove an IP address
    $0 remove -i 106.72.10.225/32 -r sa-east-1

    # List current rules
    $0 list -r sa-east-1

    # Show the security group ID
    $0 show-id -r sa-east-1

    # Add to a specific port
    $0 add -i 203.0.113.10/32 -p 443 --protocol tcp

    # Specify the security group ID directly
    $0 add -i 106.72.10.225/32 -g sg-xxxxxxxxx
EOF
    exit 1
}

# Get security group ID
get_security_group_id() {
    local region=$1
    local stack_name=$2
    local group_id=""

    echo -e "${BLUE}🔍 Retrieving security group ID...${NC}" >&2

    # Get instance ID from the stack
    local instance_id=$(aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$region" \
        --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
        --output text 2>/dev/null)

    if [[ -z "$instance_id" || "$instance_id" == "None" ]]; then
        echo -e "${RED}Error: Could not retrieve instance ID from stack $stack_name${NC}" >&2
        exit 1
    fi

    # Get security group ID from the instance
    group_id=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$region" \
        --query 'Reservations[0].Instances[0].SecurityGroups[0].GroupId' \
        --output text 2>/dev/null)

    if [[ -z "$group_id" || "$group_id" == "None" ]]; then
        echo -e "${RED}Error: Could not retrieve security group ID${NC}" >&2
        exit 1
    fi

    echo -e "${GREEN}  Retrieved: $group_id${NC}" >&2
    echo "$group_id"
}

# Add an IP address
add_ip() {
    local group_id=$1
    local ip=$2
    local region=$3
    local port=$4
    local protocol=$5
    local description=$6

    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}Add IP Address${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo "Security Group ID: $group_id"
    echo "IP address:        $ip"
    echo "Port:              $port"
    echo "Protocol:          $protocol"
    echo "Region:            $region"
    if [[ -n "$description" ]]; then
        echo "Description:       $description"
    fi
    echo -e "${BLUE}=========================================${NC}"
    echo ""

    echo -e "${BLUE}✚ Adding rule...${NC}"

    local result
    if [[ -n "$description" ]]; then
        # Use --ip-permissions format when a description is provided
        result=$(aws ec2 authorize-security-group-ingress \
            --group-id "$group_id" \
            --ip-permissions "IpProtocol=$protocol,FromPort=$port,ToPort=$port,IpRanges=[{CidrIp=$ip,Description='$description'}]" \
            --region "$region" 2>&1)
    else
        # Use simpler format when no description is provided
        result=$(aws ec2 authorize-security-group-ingress \
            --group-id "$group_id" \
            --protocol "$protocol" \
            --port "$port" \
            --cidr "$ip" \
            --region "$region" 2>&1)
    fi

    echo ""
    if echo "$result" | grep -q "InvalidPermission.Duplicate"; then
        echo -e "${YELLOW}⚠️  Rule already exists${NC}"
    elif echo "$result" | grep -q "error\|Error"; then
        echo -e "${RED}❌ Error: $result${NC}"
        exit 1
    else
        echo -e "${GREEN}✅ IP address added${NC}"
    fi
}

# Remove an IP address
remove_ip() {
    local group_id=$1
    local ip=$2
    local region=$3
    local port=$4
    local protocol=$5

    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}Remove IP Address${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo "Security Group ID: $group_id"
    echo "IP address:        $ip"
    echo "Port:              $port"
    echo "Protocol:          $protocol"
    echo "Region:            $region"
    echo -e "${BLUE}=========================================${NC}"
    echo ""

    echo -e "${YELLOW}⚠️  Removing rule${NC}"
    read -p "Continue? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Cancelled"
        exit 0
    fi

    echo ""
    echo -e "${BLUE}✖ Removing rule...${NC}"
    if aws ec2 revoke-security-group-ingress \
        --group-id "$group_id" \
        --protocol "$protocol" \
        --port "$port" \
        --cidr "$ip" \
        --region "$region" 2>&1; then
        echo ""
        echo -e "${GREEN}✅ IP address removed${NC}"
    else
        echo ""
        echo -e "${RED}❌ Failed to remove rule${NC}"
        exit 1
    fi
}

# List rules
list_rules() {
    local group_id=$1
    local region=$2

    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}Security Group Rule List${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo "Security Group ID: $group_id"
    echo "Region:            $region"
    echo -e "${BLUE}=========================================${NC}"
    echo ""

    # Retrieve inbound rules
    local rules=$(aws ec2 describe-security-groups \
        --group-ids "$group_id" \
        --region "$region" \
        --query 'SecurityGroups[0].IpPermissions' \
        --output json)

    echo -e "${GREEN}📋 Inbound rules:${NC}"
    echo ""

    # Format and display with jq
    echo "$rules" | jq -r '.[] |
        "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━",
        "Protocol: \(.IpProtocol)",
        "Port range: \(if .FromPort then "\(.FromPort)-\(.ToPort)" else "All" end)",
        (if .IpRanges then .IpRanges[] | "  CIDR: \(.CidrIp)\(if .Description then " (\(.Description))" else "" end)" else empty end),
        (if .Ipv6Ranges then .Ipv6Ranges[] | "  IPv6: \(.CidrIpv6)\(if .Description then " (\(.Description))" else "" end)" else empty end),
        (if .UserIdGroupPairs then .UserIdGroupPairs[] | "  SG: \(.GroupId)\(if .Description then " (\(.Description))" else "" end)" else empty end)
    '

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# Show security group ID
show_id() {
    local group_id=$1
    local region=$2

    echo -e "${GREEN}Security Group ID: $group_id${NC}"
    echo ""
    echo -e "${YELLOW}💡 Use this ID to manage rules:${NC}"
    echo "  # Add an IP"
    echo "  $0 add -i YOUR_IP/32 -g $group_id -r $region"
    echo ""
    echo "  # Remove an IP"
    echo "  $0 remove -i YOUR_IP/32 -g $group_id -r $region"
    echo ""
    echo "  # List rules"
    echo "  $0 list -g $group_id -r $region"
}

# Parse arguments
COMMAND=""
IP=""
GROUP_ID=""

if [[ $# -eq 0 ]]; then
    usage
fi

COMMAND=$1
shift

while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--ip)
            IP="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -s|--stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        -g|--group-id)
            GROUP_ID="$2"
            shift 2
            ;;
        -p|--port)
            PORT="$2"
            shift 2
            ;;
        --protocol)
            PROTOCOL="$2"
            shift 2
            ;;
        -d|--description)
            DESCRIPTION="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            echo -e "${RED}Error: Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Retrieve security group ID if not specified
if [[ -z "$GROUP_ID" ]]; then
    GROUP_ID=$(get_security_group_id "$REGION" "$STACK_NAME")
fi

# Execute command
case $COMMAND in
    add)
        if [[ -z "$IP" ]]; then
            echo -e "${RED}Error: --ip is required${NC}"
            usage
        fi
        # Append /32 if CIDR notation is missing
        if [[ ! "$IP" =~ /[0-9]+$ ]]; then
            IP="$IP/32"
            echo -e "${YELLOW}⚠️  Converted to CIDR notation: $IP${NC}"
        fi
        add_ip "$GROUP_ID" "$IP" "$REGION" "$PORT" "$PROTOCOL" "$DESCRIPTION"
        ;;
    remove)
        if [[ -z "$IP" ]]; then
            echo -e "${RED}Error: --ip is required${NC}"
            usage
        fi
        # Append /32 if CIDR notation is missing
        if [[ ! "$IP" =~ /[0-9]+$ ]]; then
            IP="$IP/32"
            echo -e "${YELLOW}⚠️  Converted to CIDR notation: $IP${NC}"
        fi
        remove_ip "$GROUP_ID" "$IP" "$REGION" "$PORT" "$PROTOCOL"
        ;;
    list)
        list_rules "$GROUP_ID" "$REGION"
        ;;
    show-id)
        show_id "$GROUP_ID" "$REGION"
        ;;
    *)
        echo -e "${RED}Error: Unknown command: $COMMAND${NC}"
        usage
        ;;
esac
