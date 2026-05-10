#!/bin/bash
# One-command recovery script for a Code Server instance
#
# Use cases:
#   - AWS mitigation policy replaced the SG with epoxy-mitigations-isolated-ec2-vpc-*
#   - Instance was stopped due to a Spot interruption
#   - Public IP was removed and the URL is no longer reachable
#   - Instance was set up before but you've lost the connection command
#
# Prerequisites:
#   - The neuron-code-server stack exists (deployed via ./deploy.sh)
#   - AWS_PROFILE is set to the appropriate profile (falls back to the aws CLI default if unset)
#   - Region defaults to sa-east-1 (override with --region)
#
# Usage:
#   ./scripts/recover.sh                      # Fully automatic recovery + display connection info
#   ./scripts/recover.sh --region sa-east-1   # Specify region explicitly
#   ./scripts/recover.sh --dry-run            # Diagnose only, no changes made
#   ./scripts/recover.sh --reallocate-eip     # Release the current EIP and allocate a new one
#
# Steps performed (7 steps):
#   1) Retrieve instance_id and CDK SG from the neuron-code-server stack
#      (If stack is DELETE_IN_PROGRESS / MISSING, deploy.sh is called automatically)
#   2) Diagnose instance state (stopped / SG hijacked / no Public IP, etc.)
#   3) stopped -> start (with retry logic for Spot request state updates)
#   4) Re-attach SG
#   5) Allocate EIP (reuse a free one or create a new one)
#   6) SSM Online + HTTP 302 + Code Server password sync
#   7) EFS permissions + /home/coder symlink verification and auto-repair
#   8) Display connection info (URL, password, SSM command)

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Default values
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-sa-east-1}}"
STACK_NAME="neuron-code-server"
DRY_RUN=false
REALLOCATE_EIP=false
MY_IP=""

usage() {
    cat << EOF
One-command recovery script (neuron-code-server Code Server)

Options:
    -r, --region REGION        AWS region (default: sa-east-1)
    --stack NAME               CloudFormation stack name (default: neuron-code-server)
    --dry-run                  Diagnose only, no changes made
    --reallocate-eip           Release the existing EIP and allocate a new one
    --my-ip IP                 IP to add to SG ingress (auto-detected by default)
    -h, --help                 Show this help message

Typical usage:
    # Basic recovery (run immediately when instance is down)
    ./scripts/recover.sh

    # Diagnose only to see what is wrong
    ./scripts/recover.sh --dry-run

    # Add your IP to the SG only when your IP has changed
    ./scripts/recover.sh --my-ip \$(curl -s https://checkip.amazonaws.com)/32
EOF
}

while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region) REGION="$2"; shift 2 ;;
        --stack) STACK_NAME="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        --reallocate-eip) REALLOCATE_EIP=true; shift ;;
        --my-ip) MY_IP="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo -e "${RED}unknown: $1${NC}"; usage; exit 1 ;;
    esac
done

# Check AWS_PROFILE (fall back to aws CLI default behavior if unset)
if [[ -z "${AWS_PROFILE:-}" ]]; then
    echo -e "${YELLOW}[WARN] AWS_PROFILE is not set. Continuing with the aws CLI default profile/credentials${NC}"
    echo -e "${YELLOW}       To use a specific profile, run 'export AWS_PROFILE=<profile>' and re-execute${NC}"
fi

echo -e "${BLUE}==========================================${NC}"
echo -e "${BLUE}Code Server Recovery (neuron-code-server)${NC}"
echo -e "${BLUE}==========================================${NC}"
echo "Region:     $REGION"
echo "Stack:      $STACK_NAME"
echo "Dry-run:    $DRY_RUN"
echo "Profile:    $AWS_PROFILE"
echo ""

# ---------- Step 1: Retrieve instance_id and SG from the stack ----------
echo -e "${BLUE}[1/7] Retrieving information from CloudFormation stack...${NC}"

STACK_STATUS=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "MISSING")

# If the stack is being deleted or rolled back, wait for completion and then re-deploy
if [[ "$STACK_STATUS" == "DELETE_IN_PROGRESS" || "$STACK_STATUS" == "ROLLBACK_IN_PROGRESS" ]]; then
    echo -e "${YELLOW}[WARN] Stack is in $STACK_STATUS state, waiting for deletion to complete...${NC}"
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        sleep 20
        S=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
            --query 'Stacks[0].StackStatus' --output text 2>/dev/null || echo "MISSING")
        echo "    wait $i: $S"
        if [[ "$S" == "MISSING" || "$S" == "ROLLBACK_COMPLETE" ]]; then
            STACK_STATUS="MISSING"
            break
        fi
    done
fi

# If the stack does not exist or is in ROLLBACK_COMPLETE, recreate it with deploy.sh
if [[ "$STACK_STATUS" == "MISSING" || "$STACK_STATUS" == "ROLLBACK_COMPLETE" ]]; then
    echo -e "${YELLOW}[WARN] Stack '$STACK_NAME' does not exist or is broken${NC}"
    echo "  Recreating with deploy.sh:"
    DEPLOY_CMD="./scripts/deploy.sh --use-spot --spot-max-price 1.50 --spot-interruption-behavior stop --allowed-ip $(curl -s https://checkip.amazonaws.com 2>/dev/null || echo 0.0.0.0)/32 --skip-setup --region $REGION"
    echo ""
    echo "  $DEPLOY_CMD"
    echo ""

    if [[ "$DRY_RUN" == true ]]; then
        echo "  [dry-run] would run deploy.sh + setup-code-server.sh"
        exit 0
    fi

    # Explicitly delete the stack if it is in ROLLBACK_COMPLETE
    if [[ "$STACK_STATUS" == "ROLLBACK_COMPLETE" ]]; then
        echo "  Deleting existing ROLLBACK_COMPLETE stack..."
        aws cloudformation delete-stack --stack-name "$STACK_NAME" --region "$REGION" 2>&1
        aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION" 2>&1 || true
    fi

    echo ""
    read -p "  Run deploy.sh automatically now? (yes/no): " -r CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Cancelled. Please run the above command manually."
        exit 0
    fi

    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    cd "$(dirname "$SCRIPT_DIR")"
    bash "$SCRIPT_DIR/deploy.sh" \
        --use-spot --spot-max-price 1.50 --spot-interruption-behavior stop \
        --allowed-ip "$(curl -s https://checkip.amazonaws.com 2>/dev/null || echo 0.0.0.0)/32" \
        --region "$REGION"

    # After deploy completes, re-run recover.sh to perform SSM / HTTP checks on the new instance
    echo ""
    echo -e "${BLUE}Deploy complete -> re-running recover.sh for final verification${NC}"
    exec "$SCRIPT_DIR/recover.sh" --region "$REGION"
fi

echo "  Stack status: $STACK_STATUS"

INSTANCE_ID=$(aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' --output text)
echo "  Instance ID: $INSTANCE_ID"

CDK_SG_ID=$(aws cloudformation describe-stack-resources --stack-name "$STACK_NAME" --region "$REGION" \
    --query 'StackResources[?ResourceType==`AWS::EC2::SecurityGroup`].PhysicalResourceId | [0]' --output text)
echo "  CDK SG ID:   $CDK_SG_ID"

SECRET_ARN=$(aws secretsmanager list-secrets --region "$REGION" \
    --query "SecretList[?contains(Name, 'CodeServerPassword')].ARN | [0]" --output text)
echo "  Secret ARN:  ${SECRET_ARN:0:60}..."

# ---------- Step 2: Diagnose instance state + SG ----------
echo ""
echo -e "${BLUE}[2/7] Diagnosing instance state...${NC}"

INSTANCE_INFO=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" --output json)
STATE=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].State.Name')
PUBLIC_IP=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].PublicIpAddress // "null"')
CURRENT_SGS=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].SecurityGroups[].GroupId' | sort | tr '\n' ' ')

echo "  State:       $STATE"
echo "  Public IP:   $PUBLIC_IP"
echo "  Current SG:  $CURRENT_SGS"
echo "  Expected SG: $CDK_SG_ID"

SG_NEEDS_REATTACH=false
if [[ "$CURRENT_SGS" != *"$CDK_SG_ID"* ]]; then
    echo -e "  ${YELLOW}[WARN] SG has been replaced by a mitigation policy${NC}"
    SG_NEEDS_REATTACH=true
fi

# ---------- Step 3: Stopped -> start ----------
#
# Spot instance-specific behavior:
#   - Immediately after a manual stop, the Spot request state is 'marked-for-stop' -> 'instance-stopped-by-user'
#   - Running start-instances in this state may produce an IncorrectSpotRequestState error
#   - AWS needs 10-30 seconds to update the Spot request state, so retrying will eventually succeed
if [[ "$STATE" == "stopped" ]]; then
    echo ""
    echo -e "${BLUE}[3/7] Instance is stopped -> starting (with Spot retry logic)...${NC}"
    if [[ "$DRY_RUN" == true ]]; then
        echo "  [dry-run] would: aws ec2 start-instances (with retry for Spot)"
    else
        START_OK=false
        for attempt in 1 2 3 4 5 6; do
            if aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null 2>&1; then
                echo "    start-instances attempt $attempt: OK"
                START_OK=true
                break
            else
                echo "    start-instances attempt $attempt: Spot request not yet updated, waiting 10s"
                sleep 10
            fi
        done
        if [[ "$START_OK" != true ]]; then
            echo -e "${RED}    [NG] start-instances is not succeeding. Check the Spot request state:${NC}"
            aws ec2 describe-spot-instance-requests --region "$REGION" \
                --filters "Name=instance-id,Values=$INSTANCE_ID" \
                --query 'SpotInstanceRequests[].[SpotInstanceRequestId,State,Status.Code]' --output table
            echo "  Manual action required: cancel the Spot request and redeploy with deploy.sh"
            exit 1
        fi
        for i in 1 2 3 4 5 6 7 8; do
            sleep 10
            S=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
                --query 'Reservations[0].Instances[0].State.Name' --output text)
            echo "    wait $i: state=$S"
            [[ "$S" == "running" ]] && break
        done
    fi
elif [[ "$STATE" == "running" ]]; then
    echo ""
    echo -e "${BLUE}[3/7] Instance is running${NC}"
else
    echo ""
    echo -e "${RED}[NG] Unexpected state: $STATE${NC}"
    echo "  Manual check: aws ec2 describe-instances --instance-ids $INSTANCE_ID --region $REGION"
    exit 1
fi

# ---------- Step 4: Re-attach SG ----------
if [[ "$SG_NEEDS_REATTACH" == true ]]; then
    echo ""
    echo -e "${BLUE}[4/7] Re-attaching CDK SG...${NC}"
    if [[ "$DRY_RUN" == true ]]; then
        echo "  [dry-run] would: aws ec2 modify-instance-attribute --instance-id $INSTANCE_ID --groups $CDK_SG_ID"
    else
        aws ec2 modify-instance-attribute --instance-id "$INSTANCE_ID" --region "$REGION" --groups "$CDK_SG_ID" 2>&1
        echo "  [OK] SG re-attached successfully"
    fi
else
    echo ""
    echo -e "${BLUE}[4/7] SG is correctly attached (skip)${NC}"
fi

# ---------- Step 5: Verify EIP + allocate ----------
echo ""
echo -e "${BLUE}[5/7] Checking EIP...${NC}"

ASSOCIATED_EIP=$(aws ec2 describe-addresses --region "$REGION" \
    --filters "Name=instance-id,Values=$INSTANCE_ID" \
    --query 'Addresses[0].PublicIp' --output text 2>/dev/null || echo "None")

if [[ "$ASSOCIATED_EIP" == "None" || "$ASSOCIATED_EIP" == "null" ]] || [[ "$REALLOCATE_EIP" == true ]]; then
    if [[ "$REALLOCATE_EIP" == true ]] && [[ "$ASSOCIATED_EIP" != "None" ]]; then
        echo "  Releasing existing EIP ($ASSOCIATED_EIP)..."
        OLD_ALLOC=$(aws ec2 describe-addresses --region "$REGION" \
            --filters "Name=instance-id,Values=$INSTANCE_ID" \
            --query 'Addresses[0].AllocationId' --output text)
        OLD_ASSOC=$(aws ec2 describe-addresses --region "$REGION" \
            --filters "Name=instance-id,Values=$INSTANCE_ID" \
            --query 'Addresses[0].AssociationId' --output text)
        if [[ "$DRY_RUN" != true ]]; then
            [[ "$OLD_ASSOC" != "None" ]] && aws ec2 disassociate-address --region "$REGION" --association-id "$OLD_ASSOC" > /dev/null
            aws ec2 release-address --region "$REGION" --allocation-id "$OLD_ALLOC" > /dev/null
        fi
    fi

    # Reuse a free EIP if available; otherwise allocate a new one
    FREE_EIP=$(aws ec2 describe-addresses --region "$REGION" \
        --query 'Addresses[?AssociationId==null] | [0].[AllocationId,PublicIp]' --output text 2>/dev/null)
    FREE_ALLOC=$(echo "$FREE_EIP" | awk '{print $1}')
    FREE_IP=$(echo "$FREE_EIP" | awk '{print $2}')

    if [[ "$DRY_RUN" == true ]]; then
        echo "  [dry-run] would allocate/reuse EIP and associate to $INSTANCE_ID"
    else
        if [[ -n "$FREE_ALLOC" && "$FREE_ALLOC" != "None" ]]; then
            echo "  Reusing free EIP: $FREE_IP (alloc=$FREE_ALLOC)"
            ALLOC_ID="$FREE_ALLOC"
        else
            echo "  Allocating new EIP..."
            ALLOC_ID=$(aws ec2 allocate-address --region "$REGION" --domain vpc --query 'AllocationId' --output text)
        fi
        aws ec2 associate-address --region "$REGION" --instance-id "$INSTANCE_ID" --allocation-id "$ALLOC_ID" > /dev/null
        # Wait for association to propagate
        sleep 3
        ASSOCIATED_EIP=$(aws ec2 describe-addresses --region "$REGION" \
            --filters "Name=instance-id,Values=$INSTANCE_ID" \
            --query 'Addresses[0].PublicIp' --output text)
        echo "  [OK] EIP associated: $ASSOCIATED_EIP"
    fi
else
    echo "  [OK] EIP already associated: $ASSOCIATED_EIP"
fi

# ---------- Step 5b: Add my IP to SG ingress (optional) ----------
if [[ -n "$MY_IP" ]]; then
    echo ""
    echo -e "${BLUE}[5b/7] Adding $MY_IP to SG ingress...${NC}"
    if [[ "$DRY_RUN" == true ]]; then
        echo "  [dry-run] would authorize $MY_IP:80"
    else
        aws ec2 authorize-security-group-ingress --region "$REGION" \
            --group-id "$CDK_SG_ID" \
            --ip-permissions "IpProtocol=tcp,FromPort=80,ToPort=80,IpRanges=[{CidrIp=$MY_IP,Description='User access'}]" \
            2>/dev/null && echo "  [OK] Added" || echo "  [INFO] Already exists"
    fi
fi

# ---------- Step 6: SSM Online + HTTP connectivity check + password sync ----------
echo ""
echo -e "${BLUE}[6/7] SSM Online + HTTP response check...${NC}"

if [[ "$DRY_RUN" == true ]]; then
    echo "  [dry-run] skip"
else
    # SSM
    for i in 1 2 3 4 5 6 7 8; do
        sleep 10
        P=$(aws ssm describe-instance-information --region "$REGION" \
            --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
            --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
        echo "    SSM try $i: ${P:-not-registered}"
        [[ "$P" == "Online" ]] && break
    done

    # HTTP reachability cannot be checked externally (SSM-only setup).
    # Check nginx health inside the instance via SSM send-command.
    echo "  Checking nginx response inside the instance..."
    HEALTH_ID=$(aws ssm send-command --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters 'commands=["curl -sI http://127.0.0.1/ --max-time 10 | head -1"]' \
        --query 'Command.CommandId' --output text 2>/dev/null) || true
    if [[ -n "$HEALTH_ID" ]]; then
        for i in 1 2 3 4 5; do
            sleep 5
            HS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$HEALTH_ID" --instance-id "$INSTANCE_ID" --query 'Status' --output text 2>/dev/null)
            [[ "$HS" == "Success" || "$HS" == "Failed" ]] && break
        done
        HOUT=$(aws ssm get-command-invocation --region "$REGION" --command-id "$HEALTH_ID" --instance-id "$INSTANCE_ID" --query 'StandardOutputContent' --output text 2>/dev/null)
        if [[ "$HOUT" == *"302"* || "$HOUT" == *"200"* ]]; then
            echo "    [OK] nginx localhost response: ${HOUT//$'\n'/ }"
        else
            echo "    [WARN] No nginx response: ${HOUT//$'\n'/ }"
        fi
    fi

    # Check that Secrets Manager and the instance's config.yaml have the same password
    # (workaround for a known issue where setup-code-server.sh writes a random password)
    # Wrap the entire password sync block in a subshell with || true to prevent set -e
    # from stopping execution before Step 7 if any command in this block fails
    if [[ -n "$SECRET_ARN" && "$SECRET_ARN" != "None" ]]; then
        echo "  Checking password sync..."
        (
            set +e
            SM_PW=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$REGION" --query SecretString --output text 2>/dev/null)
            if [[ -n "$SM_PW" ]]; then
                FIX_CMD="for f in /work/.config/code-server/config.yaml /home/coder/.config/code-server/config.yaml; do if sudo test -f \$f; then current=\$(sudo grep '^password:' \$f 2>/dev/null | head -1 | awk '{print \$2}'); if [ \"\$current\" != \"$SM_PW\" ]; then sudo sed -i 's|^password:.*|password: $SM_PW|' \$f; sudo sed -i '/^hashed-password:/d' \$f; sudo systemctl restart code-server@coder; echo password-synced-at \$f; fi; fi; done"
                FIX_ID=$(aws ssm send-command --region "$REGION" \
                    --instance-ids "$INSTANCE_ID" \
                    --document-name AWS-RunShellScript \
                    --parameters "commands=[\"bash -c \\\"$FIX_CMD\\\"\"]" \
                    --query 'Command.CommandId' --output text 2>/dev/null)
                if [[ -n "$FIX_ID" ]]; then
                    for i in 1 2 3 4; do
                        sleep 5
                        FIX_STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$FIX_ID" --instance-id "$INSTANCE_ID" --query 'Status' --output text 2>/dev/null)
                        [[ "$FIX_STATUS" == "Success" || "$FIX_STATUS" == "Failed" ]] && break
                    done
                    FIX_OUT=$(aws ssm get-command-invocation --region "$REGION" --command-id "$FIX_ID" --instance-id "$INSTANCE_ID" --query 'StandardOutputContent' --output text 2>/dev/null)
                    if [[ "$FIX_OUT" == *"password-synced-at"* ]]; then
                        echo "    [FIX] Password mismatch detected -> config.yaml synced to Secrets Manager value"
                    else
                        echo "    [OK] Passwords in sync (Secrets Manager matches config.yaml)"
                    fi
                fi
            fi
        ) || true
    fi
fi

# ---------- Step 7: EFS permissions + /home/coder symlink verification + auto-repair ----------
# setup-code-server.sh does not redirect /home/coder to EFS, so on the first deploy
# /mnt/efs may be owned by root:root and not writable by coder.
# (user-data handles this, but this block remains as a fallback for old deploys or manual re-runs)
if [[ "$DRY_RUN" != true ]]; then
    echo ""
    echo -e "${BLUE}[7/7] Filesystem persistence (NVMe / EFS / /home/coder / NEFF cache) verification...${NC}"

    # Transfer scripts/setup-persistence.sh to the instance via base64 and re-execute it
    # (idempotent: no-op if already OK). On Spot stop->start where NVMe is wiped,
    # this recovers by re-formatting, re-mounting, and recreating symlinks.
    set +e
    SCRIPT_DIR_LOCAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    PERSIST_LOCAL="${SCRIPT_DIR_LOCAL}/setup-persistence.sh"
    if [[ -f "$PERSIST_LOCAL" ]]; then
        PERSIST_B64=$(base64 < "$PERSIST_LOCAL" | tr -d '\n')
        PERSIST_CMD_ID=$(aws ssm send-command --region "$REGION" \
            --instance-ids "$INSTANCE_ID" \
            --document-name AWS-RunShellScript \
            --parameters "commands=[\"bash -c \\\"echo '${PERSIST_B64}' | base64 -d > /tmp/setup-persistence-full.sh && chmod +x /tmp/setup-persistence-full.sh && bash /tmp/setup-persistence-full.sh 2>&1 | tail -30\\\"\"]" \
            --query 'Command.CommandId' --output text 2>/dev/null)
        if [[ -n "$PERSIST_CMD_ID" ]]; then
            for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
                sleep 8
                PERSIST_STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$PERSIST_CMD_ID" --instance-id "$INSTANCE_ID" --query 'Status' --output text 2>/dev/null)
                [[ "$PERSIST_STATUS" == "Success" || "$PERSIST_STATUS" == "Failed" ]] && break
            done
            PERSIST_OUT=$(aws ssm get-command-invocation --region "$REGION" --command-id "$PERSIST_CMD_ID" --instance-id "$INSTANCE_ID" --query 'StandardOutputContent' --output text 2>/dev/null)
            if [[ "$PERSIST_STATUS" == "Success" ]]; then
                echo -e "  ${GREEN}[OK] setup-persistence.sh completed successfully${NC}"
                # Extract only the WRITE test results
                echo "$PERSIST_OUT" | grep -E "WRITE OK|DONE" | sed 's/^/    /'
            else
                echo -e "  ${YELLOW}[WARN] setup-persistence.sh failed (status=$PERSIST_STATUS)${NC}"
                echo "$PERSIST_OUT" | tail -10 | sed 's/^/    /'
            fi
        fi
    else
        echo "  [SKIP] setup-persistence.sh not found locally: $PERSIST_LOCAL"
    fi
    set -e
fi

# The old Step 7 logic below is kept but disabled (for compatibility)
if false; then
    EFS_FIX_CMD=$(cat <<'BASH'
set -e
CODE_USER="coder"
EFS_ROOT="/mnt/efs"
EFS_SUBPATH="/neuron-workspace"
EFS_HOME="${EFS_ROOT}${EFS_SUBPATH}/home-${CODE_USER}"
EFS_WORK="${EFS_ROOT}${EFS_SUBPATH}/work"
LINK_HOME="/home/${CODE_USER}"
LINK_WORK="/work"
CHANGED=0

# Skip if EFS is not mounted
if ! mount | grep -q "/mnt/efs"; then
    echo "EFS not mounted, skip"
    exit 0
fi

# Set /mnt/efs and subroot to 1777 sticky
if [ "$(stat -c %a "${EFS_ROOT}")" != "1777" ]; then
    sudo chmod 1777 "${EFS_ROOT}" && CHANGED=1
fi
sudo mkdir -p "${EFS_ROOT}${EFS_SUBPATH}"
if [ "$(stat -c %a "${EFS_ROOT}${EFS_SUBPATH}")" != "1777" ]; then
    sudo chmod 1777 "${EFS_ROOT}${EFS_SUBPATH}" && CHANGED=1
fi

# Prepare home-coder and work directories
sudo mkdir -p "${EFS_HOME}" "${EFS_WORK}"
sudo chown -R "${CODE_USER}:${CODE_USER}" "${EFS_HOME}" "${EFS_WORK}"
sudo chmod 750 "${EFS_HOME}" "${EFS_WORK}"

# Redirect /home/coder to EFS if it is not already a symlink
if [ ! -L "${LINK_HOME}" ]; then
    if [ -d "${LINK_HOME}" ]; then
        if [ -z "$(sudo ls -A "${EFS_HOME}" 2>/dev/null)" ]; then
            sudo rsync -aAX "${LINK_HOME}/" "${EFS_HOME}/" 2>/dev/null || true
        fi
        sudo systemctl stop code-server@${CODE_USER} 2>/dev/null || true
        sudo pkill -u "${CODE_USER}" 2>/dev/null || true
        sleep 2
        sudo mv "${LINK_HOME}" "${LINK_HOME}.pre-efs-$(date +%s)"
    fi
    sudo ln -sfn "${EFS_HOME}" "${LINK_HOME}"
    sudo chown -h "${CODE_USER}:${CODE_USER}" "${LINK_HOME}"
    CHANGED=1
fi

# Also verify the /work symlink
if [ ! -L "${LINK_WORK}" ]; then
    sudo ln -sfn "${EFS_WORK}" "${LINK_WORK}"
    sudo chown -h "${CODE_USER}:${CODE_USER}" "${LINK_WORK}"
    CHANGED=1
fi

# Reset coder user's HOME to /home/coder
CURRENT_HOME=$(getent passwd "${CODE_USER}" | cut -d: -f6)
if [ "${CURRENT_HOME}" != "${LINK_HOME}" ]; then
    sudo systemctl stop code-server@${CODE_USER} 2>/dev/null || true
    sudo pkill -u "${CODE_USER}" 2>/dev/null || true
    sleep 2
    sudo usermod -d "${LINK_HOME}" "${CODE_USER}" && CHANGED=1
fi

# systemd override (HOME=/home/coder)
OVERRIDE_DIR="/etc/systemd/system/code-server@${CODE_USER}.service.d"
if [ ! -f "${OVERRIDE_DIR}/override.conf" ]; then
    sudo mkdir -p "${OVERRIDE_DIR}"
    sudo tee "${OVERRIDE_DIR}/override.conf" > /dev/null <<EOF
[Service]
Environment=HOME=${LINK_HOME}
Environment=XDG_CONFIG_HOME=${LINK_HOME}/.config
EOF
    sudo systemctl daemon-reload
    CHANGED=1
fi

if [ "${CHANGED}" -eq 1 ]; then
    # Copy config.yaml from /work to EFS home if not already present
    sudo -u "${CODE_USER}" mkdir -p "${EFS_HOME}/.config/code-server"
    if sudo test -f "${EFS_WORK}/.config/code-server/config.yaml" && ! sudo test -f "${EFS_HOME}/.config/code-server/config.yaml"; then
        sudo cp "${EFS_WORK}/.config/code-server/config.yaml" "${EFS_HOME}/.config/code-server/config.yaml"
        sudo chown "${CODE_USER}:${CODE_USER}" "${EFS_HOME}/.config/code-server/config.yaml"
    fi
    sudo systemctl restart "code-server@${CODE_USER}"
    echo "efs-perms-fixed"
else
    echo "efs-perms-ok"
fi

# Final write test
sudo -u "${CODE_USER}" bash -c 'touch /mnt/efs/.write_test_$$ && rm /mnt/efs/.write_test_$$ && echo "/mnt/efs WRITE OK" || echo "/mnt/efs WRITE NG"'
sudo -u "${CODE_USER}" bash -c 'touch /home/coder/.write_test_$$ && rm /home/coder/.write_test_$$ && echo "/home/coder WRITE OK" || echo "/home/coder WRITE NG"'
BASH
)

    # Execute via SSM (send script as base64)
    SCRIPT_B64=$(echo "$EFS_FIX_CMD" | base64 | tr -d '\n')
    EFS_CMD_ID=$(aws ssm send-command --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters "commands=[\"bash -c \\\"echo $SCRIPT_B64 | base64 -d | bash\\\"\"]" \
        --query 'Command.CommandId' --output text 2>/dev/null)

    if [[ -n "$EFS_CMD_ID" ]]; then
        for i in 1 2 3 4 5 6; do
            sleep 8
            EFS_STATUS=$(aws ssm get-command-invocation --region "$REGION" --command-id "$EFS_CMD_ID" --instance-id "$INSTANCE_ID" --query 'Status' --output text 2>/dev/null)
            [[ "$EFS_STATUS" == "Success" || "$EFS_STATUS" == "Failed" ]] && break
        done
        EFS_OUT=$(aws ssm get-command-invocation --region "$REGION" --command-id "$EFS_CMD_ID" --instance-id "$INSTANCE_ID" --query 'StandardOutputContent' --output text 2>/dev/null)
        if [[ "$EFS_OUT" == *"efs-perms-fixed"* ]]; then
            echo -e "  ${GREEN}[FIX] EFS permissions / /home/coder symlink repaired${NC}"
        elif [[ "$EFS_OUT" == *"efs-perms-ok"* ]]; then
            echo "  [OK] EFS permissions + /home/coder are correct"
        elif [[ "$EFS_OUT" == *"EFS not mounted"* ]]; then
            echo "  [INFO] EFS not mounted (skip)"
        else
            echo -e "  ${YELLOW}[WARN] EFS verification result unknown: ${EFS_OUT:0:100}${NC}"
        fi
        # Display WRITE test results
        echo "$EFS_OUT" | grep -E "WRITE (OK|NG)" | sed 's/^/  /'
    fi
fi

# ---------- Display connection info ----------
echo ""
echo -e "${GREEN}==========================================${NC}"
echo -e "${GREEN}[DONE] Recovery complete${NC}"
echo -e "${GREEN}==========================================${NC}"
echo ""
# Profile prefix (empty if not set, "AWS_PROFILE=xxx " if set)
if [[ -n "${AWS_PROFILE:-}" ]]; then
    PROFILE_PREFIX="AWS_PROFILE=${AWS_PROFILE} "
else
    PROFILE_PREFIX=""
fi

echo "[ACCESS] 3 steps to access via SSM port forwarding:"
echo ""
echo "  Step 1a) Quick: use deploy.sh --port-forward:"
echo "    ${PROFILE_PREFIX}bash $(dirname "$0")/deploy.sh --port-forward --stack-name $STACK_NAME -p 8080:80 -r $REGION"
echo ""
echo "  Step 1b) Raw command: use aws ssm directly (separate terminal, keep running):"
echo "    ${PROFILE_PREFIX}aws ssm start-session --target $INSTANCE_ID --region $REGION \\"
echo "      --document-name AWS-StartPortForwardingSession \\"
echo "      --parameters '{\"portNumber\":[\"80\"],\"localPortNumber\":[\"8080\"]}'"
echo ""
echo "  Step 2) Open http://localhost:8080 in your browser"
echo ""
if [[ -n "$SECRET_ARN" && "$SECRET_ARN" != "None" ]]; then
    if [[ "$DRY_RUN" == true ]]; then
        PASSWORD="(dry-run: get from secret)"
    else
        PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$REGION" --query 'SecretString' --output text 2>/dev/null)
    fi
    echo "  Step 3) Password (enter on the login screen):"
    echo "    $PASSWORD"
    echo ""
fi
echo "[CONN] SSM shell connection (for debugging):"
echo "  ${PROFILE_PREFIX}aws ssm start-session --target $INSTANCE_ID --region $REGION"
echo ""
echo "[WARN] External HTTP endpoint is closed. Direct http access via Public IP is not available (public HTTP endpoints are blocked)"
echo ""
echo "If the instance goes down again, re-run this script: ./scripts/recover.sh"
echo -e "${GREEN}==========================================${NC}"
