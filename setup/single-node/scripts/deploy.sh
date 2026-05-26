#!/bin/bash
# deploy.sh - one-shot CDK deploy + code-server setup for a single Neuron DLAMI instance.

set -e

# ANSI colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
    cat << EOF
deploy.sh - CDK deploy + code-server setup for a Neuron DLAMI instance.

Usage: $0 [OPTIONS]

Options:
    -r, --region REGION                  AWS region (required; or set AWS_REGION / AWS_DEFAULT_REGION)
    -t, --instance-type TYPE             EC2 instance type (default: trn2.3xlarge)
    --use-capacity-block                 Launch against a Capacity Block reservation
    --capacity-reservation-id ID         Capacity Reservation id (implies --use-capacity-block)
    --slot NAME                          Named Capacity Block slot in SSM Parameter Store
                                         (see manage-capacity-block.sh save-params --slot).
                                         Use this when you manage multiple reservations side by side.
                                         Default: "default" (legacy flat layout).
    --use-spot                           Launch as a Spot instance (mutually exclusive with Capacity Block)
    --spot-max-price PRICE               Spot max price in USD/hr (default: on-demand price)
    --spot-interruption-behavior BEHAVIOR
                                         Spot interruption behavior [terminate|stop|hibernate]
                                         (default: terminate)
    --subnet-id ID                       Subnet id to launch in
    --volume-size SIZE                   Root EBS size in GB (default: 500)
    --efs-id ID                          EFS file system id for persistent /home/coder and /work
                                         (falls back to config.json regions[REGION].defaultEfsId if unset)
    --efs-subpath PATH                   Subpath inside the EFS (default: /neuron-workspace)
    --no-efs                             Disable EFS entirely for this stack
    --create-efs                         Provision EFS via CDK as a separate stack (<stackName>-efs)
                                         and use it for persistence. Implies --efs-id from the new stack.
    --create-alb-backend                 Provision AlbBackendStack (<stackName>-alb) after the EC2 stack.
                                         Internal ALB + 5 target groups (code-server + 4 app routes).
                                         ALB SG starts zero-ingress; opened later by Phase C/D.
    --create-cognito                     Provision CognitoOperatorStack (<stackName>-cognito).
                                         UserPool + Hosted UI domain on *.amazoncognito.com.
                                         Self-signup is disabled (admin-only operator accounts).
    --cognito-domain-prefix PREFIX       Override the Hosted UI subdomain prefix
                                         (default: derived from <stackName>-cognito).
    --create-cloudfront-frontend         Provision CloudFrontFrontendStack (<stackName>-frontend).
                                         Requires --create-alb-backend and --create-cognito in the
                                         same run. Adds the OAuth Lambda + CloudFront Function
                                         (HMAC verify) + VPC Origin + UserPoolClient and opens the
                                         ALB SG to the CloudFront origin-facing prefix list.
    --full                               Shortcut: turn on --create-efs --create-alb-backend
                                         --create-cognito --create-cloudfront-frontend in one go.
                                         Combined with --operator-email / --operator-password
                                         this gives a one-shot login-ready deploy.
    --operator-email EMAIL               Bootstrap a Cognito operator user at deploy time.
                                         Requires --operator-password (or --operator-password-secret-arn).
                                         Implies --create-cognito.
    --operator-password PASSWORD         Permanent password for the bootstrapped operator. The
                                         script writes it to a Secrets Manager secret named
                                         <stackName>-operator-password and passes ONLY the ARN
                                         to CDK so the password never lands in the CFN template,
                                         cdk.out, or drift diffs. Must satisfy the Cognito
                                         password policy (>= 12 chars, lower/upper/digit).
    --operator-password-secret-arn ARN   Use an existing Secrets Manager secret instead of
                                         creating one. The SecretString IS the password.
    --stack-name NAME                    CloudFormation stack name (default: neuron-code-server)
    --project TAG                        Value for the Project tag on the instance
    --purpose TAG                        Value for the Purpose tag on the instance
    --skip-setup                         Skip the code-server setup tasks after deploy
    --install-claude-code                Opt-in: install the Anthropic Claude Code CLI on the
                                         instance and attach a scoped Bedrock inline policy
                                         so the CLI can invoke Bedrock foundation models.
                                         Also installs neuron-agentic-development (agents and
                                         skills) into ~/.claude for the code-server user.
                                         Default: off.
    --show-info                          Show connection info for an already-deployed stack
    --port-forward                       Open SSM port forwards against an existing stack
    -p, --ports MAP                      Port forward map (comma-separated)
                                         format: LOCAL:REMOTE[,LOCAL:REMOTE...]
                                         e.g.  -p 3000:80
                                               -p 3000:23000,3001:23001,3002:23002
    --profile PROFILE                    AWS profile (equivalent to env AWS_PROFILE)
    --destroy                            Destroy the stack and clean up cross-SG references
    --create-alb-backend                 Provision the AlbBackendStack (<stackName>-alb)
                                         right after the EC2 stack. The ALB starts with zero
                                         ingress; only the future CloudFront frontend stack
                                         opens it. (Cognito + CloudFront frontend deployment
                                         is being rebuilt per ADR-005 and will land in a
                                         separate flag once ready.)
    -h, --help                           Show this help

Environment variables:
    NEURON_AMI_SSM_PARAMETER             Override the SSM parameter used to resolve the AMI.
                                         Defaults to the public Neuron multi-framework DLAMI for
                                         Ubuntu 24.04. Set to a private/beta SSM parameter to use
                                         a non-GA AMI.
    TASK_MAX_WAIT_SECONDS                Per-task SSM completion timeout used by run-tasks.sh
                                         (default: 1800).

Examples:
    # Basic on-demand deploy in us-west-2
    $0 -r us-west-2

    # Deploy with a Capacity Block reservation
    $0 -r us-west-2 --use-capacity-block \\
       --capacity-reservation-id cr-EXAMPLE1234567890 \\
       --subnet-id subnet-EXAMPLE1234567890

    # Deploy as Spot with stop-on-interruption (stateful workloads)
    $0 -r us-west-2 --use-spot --spot-interruption-behavior stop

    # Deploy a second stack named differently so multiple instances coexist
    $0 -r us-west-2 --stack-name neuron-training-a \\
       --efs-subpath /neuron-workspace/training-a \\
       --use-spot --spot-interruption-behavior stop

    # Show connection info for an existing stack
    $0 -r us-west-2 --show-info --stack-name neuron-training-a

    # Forward a single port (local 3000 -> instance 80 which is nginx -> code-server)
    $0 -r us-west-2 --port-forward --stack-name neuron-training-a -p 3000:80

    # Forward multiple ports in one invocation
    $0 -r us-west-2 --port-forward --stack-name neuron-training-a \\
       -p 3000:80,3001:23001,3002:23002

    # Deploy with the Anthropic Claude Code CLI and the neuron-agentic-development
    # agents and skills preinstalled for the code-server user. This also attaches a
    # scoped Bedrock inline policy to the instance role (the default deploy does not).
    $0 -r us-west-2 --stack-name neuron-ws --install-claude-code

    # Destroy the stack (revokes cross-SG NFS rule, then cdk destroy)
    $0 -r us-west-2 --destroy --stack-name neuron-training-a

    # Provision the internal ALB backend after the EC2 stack succeeds.
    # The ALB stays unreachable until the CloudFront frontend stack
    # (separate, pending) wires inbound from the CloudFront origin-
    # facing prefix list.
    $0 -r sa-east-1 --use-spot --spot-interruption-behavior stop \\
       --stack-name neuron-ws --create-alb-backend

    # One-shot deploy of the entire frontend chain plus an operator user
    # that can sign in via the Cognito Hosted UI immediately. The
    # password is staged in Secrets Manager and only the ARN flows
    # through CDK context — it never lands in the CFN template.
    $0 -r sa-east-1 --use-spot --spot-interruption-behavior stop \\
       --stack-name neuron-ws --full \\
       --operator-email ops@example.com --operator-password 'StrongPwd123'
EOF
}

# Defaults
REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
INSTANCE_TYPE="trn2.3xlarge"
USE_CAPACITY_BLOCK=false
CAPACITY_RESERVATION_ID=""
# Named Capacity Block slot inside SSM Parameter Store. "default" reads
# the legacy /capacity-block/<region>/reservation-id key; any other
# value reads /capacity-block/<region>/slots/<name>/.
CB_SLOT="default"
USE_SPOT=false
SPOT_MAX_PRICE=""
SPOT_INTERRUPTION_BEHAVIOR="terminate"
EFS_ID=""
EFS_SUBPATH=""
NO_EFS=false
SUBNET_ID=""
VOLUME_SIZE="500"
SKIP_SETUP=false
INSTALL_CLAUDE_CODE=false
SHOW_INFO=false
DESTROY=false
PORT_FORWARD=false
PORTS=""
PROFILE_ARG=""
STACK_NAME="neuron-code-server"
PROJECT=""
PURPOSE=""
# CloudFront frontend (browser access) was removed with ADR-005; a
# replacement stack (Cognito Hosted UI + HMAC opaque cookie) will land
# behind a new flag in a follow-up commit.
# Create EFS in CDK as a separate stack and use it for persistence. Off by default.
CREATE_EFS=false
# Phase B opt-in: deploy AlbBackendStack alongside the EC2 stack so the
# operator-facing ALB and 5 target groups are ready for Phase C / D.
CREATE_ALB_BACKEND=false
# Phase C: deploy CognitoOperatorStack (UserPool + Hosted UI domain).
CREATE_COGNITO=false
COGNITO_DOMAIN_PREFIX=""
# Phase D: deploy CloudFrontFrontendStack (ADR-005 frontend). Requires
# Phase B + C in the same deploy because the stack consumes their L2
# references directly (not via CFN imports / fromLookup).
CREATE_CLOUDFRONT_FRONTEND=false
# Optional one-shot operator bootstrap (ADR-013). Email + password go
# to Cognito at deploy time so the operator can log in immediately.
OPERATOR_EMAIL=""
OPERATOR_PASSWORD=""
OPERATOR_PASSWORD_SECRET_ARN=""

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
        --use-capacity-block)
            USE_CAPACITY_BLOCK=true
            shift
            ;;
        --capacity-reservation-id)
            CAPACITY_RESERVATION_ID="$2"
            USE_CAPACITY_BLOCK=true
            shift 2
            ;;
        --slot)
            CB_SLOT="$2"
            USE_CAPACITY_BLOCK=true
            shift 2
            ;;
        --use-spot)
            USE_SPOT=true
            shift
            ;;
        --spot-max-price)
            SPOT_MAX_PRICE="$2"
            USE_SPOT=true
            shift 2
            ;;
        --spot-interruption-behavior)
            SPOT_INTERRUPTION_BEHAVIOR="$2"
            USE_SPOT=true
            shift 2
            ;;
        --efs-id)
            EFS_ID="$2"
            shift 2
            ;;
        --efs-subpath)
            EFS_SUBPATH="$2"
            shift 2
            ;;
        --no-efs)
            NO_EFS=true
            shift
            ;;
        --subnet-id)
            SUBNET_ID="$2"
            shift 2
            ;;
        --volume-size)
            VOLUME_SIZE="$2"
            shift 2
            ;;
        --allowed-ip)
            echo -e "${YELLOW}[WARN] --allowed-ip is ignored: this stack is SSM-only and no ingress is opened.${NC}" >&2
            echo -e "${YELLOW}       Access code-server via: aws ssm start-session --document-name AWS-StartPortForwardingSession${NC}" >&2
            shift 2
            ;;
        --stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        --project)
            PROJECT="$2"
            shift 2
            ;;
        --purpose)
            PURPOSE="$2"
            shift 2
            ;;
        --skip-setup)
            SKIP_SETUP=true
            shift
            ;;
        --install-claude-code)
            INSTALL_CLAUDE_CODE=true
            shift
            ;;
        --show-info)
            SHOW_INFO=true
            shift
            ;;
        --port-forward)
            PORT_FORWARD=true
            shift
            ;;
        -p|--ports)
            PORTS="$2"
            shift 2
            ;;
        --profile)
            PROFILE_ARG="$2"
            shift 2
            ;;
        --destroy)
            DESTROY=true
            shift
            ;;
        --create-efs)
            # Provision EFS via CDK as a separate stack `<stackName>-efs`,
            # then use the new file system for persistence. Implies and
            # supersedes any --efs-id provided.
            CREATE_EFS=true
            shift
            ;;
        --create-alb-backend)
            # Provision the AlbBackendStack (`<stackName>-alb`) right after
            # the EC2 stack succeeds. The ALB starts with zero ingress; only
            # the future CloudFront frontend stack (per ADR-005) will open
            # it up. This stack is safe to deploy on its own.
            CREATE_ALB_BACKEND=true
            shift
            ;;
        --create-cognito)
            # Provision the CognitoOperatorStack (`<stackName>-cognito`)
            # alongside the EC2 stack. Independent of ALB / CloudFront, but
            # the CloudFront frontend stack consumes its UserPool.
            CREATE_COGNITO=true
            shift
            ;;
        --cognito-domain-prefix)
            COGNITO_DOMAIN_PREFIX="$2"
            CREATE_COGNITO=true
            shift 2
            ;;
        --create-cloudfront-frontend)
            # Provision the CloudFrontFrontendStack (`<stackName>-frontend`).
            # Hard-requires --create-alb-backend AND --create-cognito in
            # the same invocation because bin/app.ts wires the L2 refs
            # directly (no CFN import).
            CREATE_CLOUDFRONT_FRONTEND=true
            shift
            ;;
        --full)
            # One-shot deploy of the entire ADR-005 stack family:
            # EFS persistence + ALB backend + Cognito + CloudFront frontend.
            # Combine with --operator-email / --operator-password for an
            # end-to-end login-ready environment from a single command.
            CREATE_EFS=true
            CREATE_ALB_BACKEND=true
            CREATE_COGNITO=true
            CREATE_CLOUDFRONT_FRONTEND=true
            shift
            ;;
        --operator-email)
            OPERATOR_EMAIL="$2"
            CREATE_COGNITO=true
            shift 2
            ;;
        --operator-password)
            OPERATOR_PASSWORD="$2"
            CREATE_COGNITO=true
            shift 2
            ;;
        --operator-password-secret-arn)
            OPERATOR_PASSWORD_SECRET_ARN="$2"
            CREATE_COGNITO=true
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo -e "${RED}Error: unknown option: $1${NC}"
            usage
            exit 1
            ;;
    esac
done

if [[ -z "$REGION" ]]; then
    echo -e "${RED}Error: region is required. Use -r / --region, or set AWS_REGION / AWS_DEFAULT_REGION.${NC}" >&2
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
CDK_DIR="$PROJECT_DIR/cdk"

# ----------------------------------------------------------------------
# Credentials keepalive (credential_process / SSO TTL workaround)
#
# Long-running deploys (CDK + SSM run-tasks combined > 30 min) regularly
# hit `SignatureDoesNotMatch: Signature expired ... is now earlier than
# ...` because a node SDK process inside `cdk deploy` resolves credentials
# once at startup and reuses the cached value across CFN polling, even
# after the underlying credential_process credentials have rolled over.
#
# Fix: every time control returns to bash, force a refresh by issuing a
# light `sts get-caller-identity`. That triggers the configured AWS
# credential_process helper to mint a fresh access key set, which
# subsequent child processes will inherit.
#
# In addition, kick off a background watchdog that performs the same
# refresh every CREDS_REFRESH_INTERVAL seconds so even single
# long-running children (cdk deploy / SSM Run Command waiters) see fresh
# credentials whenever they re-resolve. The watchdog is best-effort; it
# is killed in EXIT trap regardless of how the script terminates.
# ----------------------------------------------------------------------
CREDS_REFRESH_INTERVAL="${CREDS_REFRESH_INTERVAL:-600}"
CREDS_WATCHDOG_PID=""

aws_creds_refresh() {
    aws sts get-caller-identity --output text >/dev/null 2>&1 || true
}

start_creds_watchdog() {
    if [[ -n "$CREDS_WATCHDOG_PID" ]]; then
        return 0
    fi
    aws_creds_refresh
    (
        while sleep "$CREDS_REFRESH_INTERVAL"; do
            aws sts get-caller-identity --output text >/dev/null 2>&1 || true
        done
    ) &
    CREDS_WATCHDOG_PID=$!
    disown "$CREDS_WATCHDOG_PID" 2>/dev/null || true
}

stop_creds_watchdog() {
    if [[ -n "$CREDS_WATCHDOG_PID" ]] && kill -0 "$CREDS_WATCHDOG_PID" 2>/dev/null; then
        kill "$CREDS_WATCHDOG_PID" 2>/dev/null || true
    fi
    CREDS_WATCHDOG_PID=""
}

trap 'stop_creds_watchdog' EXIT INT TERM

# Kick the watchdog now so every subsequent AWS call benefits.
start_creds_watchdog

# ----------------------------------------------------------------------
# Helper: idempotently authorize / revoke NFS (2049/tcp) on the EFS mount
# target security group(s) from this stack's EC2 security group.
#
# Background: when CDK creates a new EC2 security group for the instance,
# the EFS mount target security group still restricts NFS to whatever was
# there before. Without this helper the user has to run
# `authorize-security-group-ingress` manually after every deploy, which
# defeats the point of a one-shot deploy script. The EFS file system
# itself is assumed to exist already and to be managed outside this stack
# (so its mount-target SG survives stack destroy).
#
# Arguments:
#   $1: "authorize" or "revoke"
#   $2: EFS file system id (fs-xxxxx)
#   $3: Source EC2 security group id (sg-xxxxx)
#   $4: Description (optional, authorize only)
#   $5: Region
#
# Idempotent:
#   authorize: if a matching rule already exists, we warn and keep going
#   revoke:    if no matching rule exists, we treat it as success
# ----------------------------------------------------------------------
manage_efs_mt_ingress() {
    local action="$1"
    local fs_id="$2"
    local ec2_sg="$3"
    local description="${4:-managed by deploy.sh}"
    local region="$5"

    if [[ -z "$fs_id" ]] || [[ "$fs_id" == "none" ]] || [[ -z "$ec2_sg" ]]; then
        echo -e "${YELLOW}[EFS-SG] skip (fs_id=$fs_id, ec2_sg=$ec2_sg)${NC}"
        return 0
    fi

    # Discover all mount targets for the file system.
    local mt_ids
    mt_ids=$(aws efs describe-mount-targets \
        --file-system-id "$fs_id" \
        --region "$region" \
        --query 'MountTargets[*].MountTargetId' \
        --output text 2>/dev/null)
    if [[ -z "$mt_ids" ]]; then
        echo -e "${YELLOW}[EFS-SG] No mount targets found for EFS $fs_id${NC}"
        return 0
    fi

    # Collect the NFS-allowing security group(s) on each mount target.
    local mt_sgs=""
    for mt_id in $mt_ids; do
        local sg
        sg=$(aws efs describe-mount-target-security-groups \
            --mount-target-id "$mt_id" \
            --region "$region" \
            --query 'SecurityGroups[*]' \
            --output text 2>/dev/null)
        for s in $sg; do
            # de-duplicate
            if ! echo "$mt_sgs" | tr ' ' '\n' | grep -q "^${s}$"; then
                mt_sgs="$mt_sgs $s"
            fi
        done
    done

    if [[ -z "$mt_sgs" ]]; then
        echo -e "${YELLOW}[EFS-SG] Could not resolve mount target security groups${NC}"
        return 0
    fi

    for mt_sg in $mt_sgs; do
        case "$action" in
            authorize)
                local out
                out=$(aws ec2 authorize-security-group-ingress \
                    --group-id "$mt_sg" \
                    --region "$region" \
                    --ip-permissions "IpProtocol=tcp,FromPort=2049,ToPort=2049,UserIdGroupPairs=[{GroupId=$ec2_sg,Description='$description'}]" \
                    --output json 2>&1)
                local rc=$?
                if [[ $rc -eq 0 ]]; then
                    echo -e "${GREEN}[EFS-SG] authorize OK: $mt_sg <- $ec2_sg tcp/2049${NC}"
                elif echo "$out" | grep -q "InvalidPermission.Duplicate"; then
                    echo -e "${YELLOW}[EFS-SG] already authorized: $mt_sg <- $ec2_sg${NC}"
                else
                    echo -e "${RED}[EFS-SG] authorize FAILED: $mt_sg <- $ec2_sg${NC}"
                    echo "$out" | head -5
                    return 1
                fi
                ;;
            revoke)
                local out
                out=$(aws ec2 revoke-security-group-ingress \
                    --group-id "$mt_sg" \
                    --region "$region" \
                    --ip-permissions "IpProtocol=tcp,FromPort=2049,ToPort=2049,UserIdGroupPairs=[{GroupId=$ec2_sg}]" \
                    --output json 2>&1)
                local rc=$?
                if [[ $rc -eq 0 ]]; then
                    echo -e "${GREEN}[EFS-SG] revoke OK: $mt_sg <- $ec2_sg tcp/2049${NC}"
                elif echo "$out" | grep -qE "InvalidPermission.NotFound|does not exist"; then
                    echo -e "${YELLOW}[EFS-SG] Rule already absent: $mt_sg <- $ec2_sg${NC}"
                else
                    echo -e "${YELLOW}[EFS-SG] Revoke warning: $mt_sg <- $ec2_sg${NC}"
                    echo "$out" | head -3
                fi
                ;;
        esac
    done
}

# AWS profile resolution:
#   1) --profile argument > 2) existing AWS_PROFILE env > 3) default chain
# Nothing is hard-coded so the script works against any profile.
if [[ -n "$PROFILE_ARG" ]]; then
    export AWS_PROFILE="$PROFILE_ARG"
fi
if [[ -n "${AWS_PROFILE:-}" ]]; then
    PROFILE_PREFIX="AWS_PROFILE=${AWS_PROFILE} "
else
    PROFILE_PREFIX=""
fi

echo -e "${BLUE}=========================================${NC}"
echo -e "${BLUE}CDK deploy${NC}"
echo -e "${BLUE}=========================================${NC}"
# Mutual exclusion check (fail fast for a better UX)
if [[ "$USE_CAPACITY_BLOCK" == true ]] && [[ "$USE_SPOT" == true ]]; then
    echo -e "${RED}Error: --use-capacity-block and --use-spot are mutually exclusive${NC}"
    exit 1
fi

echo "CDK directory:   $CDK_DIR"
echo "Region:          $REGION"
echo "Instance type:   $INSTANCE_TYPE"
echo "Capacity Block:  $USE_CAPACITY_BLOCK"
if [[ "$USE_CAPACITY_BLOCK" == true ]]; then
    echo "  Capacity Reservation ID: $CAPACITY_RESERVATION_ID"
    echo "  Subnet ID:               $SUBNET_ID"
fi
echo "Spot:            $USE_SPOT"
if [[ "$USE_SPOT" == true ]]; then
    echo "  Spot max price:          ${SPOT_MAX_PRICE:-(on-demand price ceiling)}"
    echo "  Interruption behavior:   ${SPOT_INTERRUPTION_BEHAVIOR}"
fi
echo "Volume size:     ${VOLUME_SIZE} GB"
echo -e "${BLUE}=========================================${NC}"
echo ""

# Port forward mode.
# Opens one or more SSM port forwards against an existing stack.
#   -p LOCAL:REMOTE[,LOCAL:REMOTE...]
#     e.g. -p 3000:80                        -> localhost:3000 -> instance:80
#          -p 3000:80,3001:23001,3002:23002  -> three forwards in parallel
# Each forward runs in the background. A trap cleans them up on exit.
# For multiple stacks, run this command once per stack in separate terminals.
if [[ "$PORT_FORWARD" == true ]]; then
    if [[ -z "$PORTS" ]]; then
        echo -e "${RED}Error: --port-forward requires -p / --ports${NC}"
        echo "  e.g. -p 3000:80  or  -p 3000:80,3001:23001"
        exit 1
    fi

    echo -e "${BLUE}[INFO] Port forward mode${NC}"
    echo "  Stack:   $STACK_NAME"
    echo "  Region:  $REGION"
    [[ -n "${AWS_PROFILE:-}" ]] && echo "  Profile: $AWS_PROFILE" || echo "  Profile: (default credential chain)"
    echo "  Ports:   $PORTS"
    echo ""

    # Resolve InstanceId from the CFN stack outputs.
    INSTANCE_ID=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
        --output text 2>/dev/null)

    if [[ -z "$INSTANCE_ID" ]] || [[ "$INSTANCE_ID" == "None" ]]; then
        echo -e "${RED}[NG] Cannot read InstanceId from stack '$STACK_NAME'${NC}"
        echo "  Verify the stack exists with --show-info first."
        exit 1
    fi
    echo "  Instance: $INSTANCE_ID"
    echo ""

    # Parse port map (comma-separated, each pair LOCAL:REMOTE)
    IFS=',' read -r -a PAIRS <<< "$PORTS"
    if [[ ${#PAIRS[@]} -eq 0 ]]; then
        echo -e "${RED}Error: -p value is empty${NC}"
        exit 1
    fi

    # Pre-validate every pair before launching anything.
    for p in "${PAIRS[@]}"; do
        if [[ ! "$p" =~ ^[0-9]+:[0-9]+$ ]]; then
            echo -e "${RED}Error: invalid port map '$p' (expected LOCAL:REMOTE, digits only)${NC}"
            exit 1
        fi
    done

    # Launch each forward in the background.
    PIDS=()
    LABELS=()

    cleanup_pf() {
        echo ""
        echo -e "${YELLOW}[INFO] Terminating port forward sessions...${NC}"
        for pid in "${PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid" 2>/dev/null || true
            fi
        done
        # The SSM session spawns a session-manager-plugin child; make sure it dies too.
        for pid in "${PIDS[@]}"; do
            pkill -P "$pid" 2>/dev/null || true
        done
        wait 2>/dev/null || true
        echo -e "${GREEN}[OK] Done${NC}"
    }
    trap cleanup_pf INT TERM EXIT

    for p in "${PAIRS[@]}"; do
        LOCAL="${p%%:*}"
        REMOTE="${p##*:}"
        echo -e "${BLUE}[FWD] localhost:${LOCAL} -> ${INSTANCE_ID}:${REMOTE}${NC}"

        # AWS_PROFILE has already been exported to the environment if set.
        aws ssm start-session \
            --target "$INSTANCE_ID" \
            --region "$REGION" \
            --document-name AWS-StartPortForwardingSession \
            --parameters "{\"portNumber\":[\"${REMOTE}\"],\"localPortNumber\":[\"${LOCAL}\"]}" \
            &
        PID=$!
        PIDS+=("$PID")
        LABELS+=("${LOCAL}->${REMOTE}(pid=$PID)")
    done

    echo ""
    echo -e "${GREEN}[OK] Started ${#PIDS[@]} port forward(s)${NC}"
    for i in "${!LABELS[@]}"; do
        echo "  [$((i+1))] ${LABELS[$i]}"
    done
    echo ""
    echo -e "${YELLOW}[INFO] Ctrl+C to terminate all sessions${NC}"
    echo "  Open http://localhost:<LOCAL_PORT> in your browser."
    echo ""

    # If any forward dies, take the whole group down so the user notices.
    wait -n 2>/dev/null || wait
    exit 0
fi

# Show stack info mode
if [[ "$SHOW_INFO" == true ]]; then
    echo -e "${BLUE}[INFO] Reading stack information...${NC}"
    echo ""

    STACK_STATUS=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text 2>/dev/null)

    if [[ -z "$STACK_STATUS" ]]; then
        echo -e "${RED}[NG] Stack '$STACK_NAME' not found${NC}"
        echo "Region: $REGION"
        exit 1
    fi

    echo -e "${GREEN}Stack:  $STACK_NAME${NC}"
    echo "Status: $STACK_STATUS"
    echo "Region: $REGION"
    echo ""

    INSTANCE_ID=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
        --output text)

    PUBLIC_DNS=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`InstancePublicDnsName`].OutputValue' \
        --output text)

    PUBLIC_IP=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" \
        --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`InstancePublicIp`].OutputValue' \
        --output text)

    # Resolve the Secrets Manager ARN belonging to this specific stack.
    SECRET_ARN=$(aws secretsmanager list-secrets \
        --region "$REGION" \
        --query "SecretList[?contains(Name, 'CodeServerPassword') && Tags[?Key=='aws:cloudformation:stack-name' && Value=='$STACK_NAME']].ARN | [0]" \
        --output text)

    echo -e "${GREEN}[INFO] Instance:${NC}"
    echo "  Instance ID: ${INSTANCE_ID:-'N/A'}"
    echo "  Public DNS:  ${PUBLIC_DNS:-'N/A'}"
    echo "  Public IP:   ${PUBLIC_IP:-'N/A'}"
    echo ""

    if [[ -n "$INSTANCE_ID" ]] && [[ "$INSTANCE_ID" != "None" ]]; then
        echo -e "${BLUE}[CHECK] Instance details:${NC}"

        INSTANCE_INFO=$(aws ec2 describe-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$REGION" \
            --output json 2>/dev/null)

        RESERVATIONS_COUNT=$(echo "$INSTANCE_INFO" | jq '.Reservations | length')

        if [[ "$RESERVATIONS_COUNT" -gt 0 ]]; then
            INSTANCE_STATE=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].State.Name')
            INSTANCE_TYPE_INFO=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].InstanceType')
            AZ=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].Placement.AvailabilityZone')
            LAUNCH_TIME=$(echo "$INSTANCE_INFO" | jq -r '.Reservations[0].Instances[0].LaunchTime')

            echo "  State:             ${INSTANCE_STATE:-'N/A'}"
            echo "  Instance type:     ${INSTANCE_TYPE_INFO:-'N/A'}"
            echo "  Availability zone: ${AZ:-'N/A'}"
            echo "  Launch time:       ${LAUNCH_TIME:-'N/A'}"
        else
            echo -e "  ${YELLOW}[WARN] Instance not found (may have been terminated)${NC}"
        fi
        echo ""
    fi

    echo -e "${GREEN}[ACCESS] SSM port forwarding, 3 steps:${NC}"
    if [[ -n "$INSTANCE_ID" ]] && [[ "$INSTANCE_ID" != "None" ]]; then
        echo ""
        echo "  Step 1a) Recommended: use this script's --port-forward mode:"
        echo "    ${PROFILE_PREFIX}bash $0 --port-forward --stack-name $STACK_NAME -p 8080:80 -r $REGION"
        echo ""
        echo "  Step 1b) Raw equivalent with aws CLI:"
        echo "    ${PROFILE_PREFIX}aws ssm start-session --target $INSTANCE_ID --region $REGION \\"
        echo "      --document-name AWS-StartPortForwardingSession \\"
        echo "      --parameters '{\"portNumber\":[\"80\"],\"localPortNumber\":[\"8080\"]}'"
        echo ""
        echo "  Step 2) Open http://localhost:8080 in your browser"
    fi

    if [[ -n "$SECRET_ARN" ]] && [[ "$SECRET_ARN" != "None" ]]; then
        echo ""
        echo "  Step 3) Fetch the login password:"
        echo "    ${PROFILE_PREFIX}aws secretsmanager get-secret-value --secret-id $SECRET_ARN --region $REGION --query 'SecretString' --output text"
        SHOW_INFO_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$REGION" --query 'SecretString' --output text 2>/dev/null)
        if [[ -n "$SHOW_INFO_PASSWORD" ]] && [[ "$SHOW_INFO_PASSWORD" != "None" ]]; then
            echo ""
            echo -e "    ${GREEN}[$STACK_NAME] password = $SHOW_INFO_PASSWORD${NC}"
        fi
    fi

    if [[ -n "$INSTANCE_ID" ]] && [[ "$INSTANCE_ID" != "None" ]]; then
        echo ""
        echo "  Shell session (debugging):"
        echo "    ${PROFILE_PREFIX}aws ssm start-session --target $INSTANCE_ID --region $REGION"
    fi

    echo ""
    echo -e "  ${YELLOW}[NOTE] The public IP and DNS are not reachable from the internet - the security group has no ingress.${NC}"

    echo ""
    exit 0
fi

# Destroy mode
if [[ "$DESTROY" == true ]]; then
    echo -e "${YELLOW}[WARN] About to destroy the stack '$STACK_NAME' in $REGION${NC}"
    read -p "Are you sure? (yes/no): " -r
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        echo "Cancelled"
        exit 0
    fi

    # Tear-down order (reverse of deploy, post-ADR-011):
    #   D. CloudFrontFrontendStack  - owns the ALB SG inbound + UserPoolClient
    #   B. AlbBackendStack          - hosts the OAuth Lambda which references
    #                                 Cognito UserPool, so MUST go before Cognito
    #   C. CognitoOperatorStack     - UserPool can only go after the Lambda
    #   A. NeuronCodeServerStack    - last, plus EFS / EFS-MT cleanup
    FRONTEND_STACK_NAME="${STACK_NAME}-frontend"
    if aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK_NAME" \
        --region "$REGION" >/dev/null 2>&1; then
        echo -e "${BLUE}[DESTROY] CloudFrontFrontendStack $FRONTEND_STACK_NAME -> remove first${NC}"
        cd "$CDK_DIR"
        AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
            npm run destroy -- "$FRONTEND_STACK_NAME" -c "stackName=$STACK_NAME" \
                -c "createAlbBackend=true" -c "albEc2InstanceId=stub" -c "albEc2SecurityGroupId=stub" \
                -c "createCognito=true" -c "createCloudFrontFrontend=true" --force || \
            echo -e "${YELLOW}[WARN] CloudFrontFrontend destroy returned non-zero; continuing${NC}"
    fi

    ALB_STACK_NAME="${STACK_NAME}-alb"
    if aws cloudformation describe-stacks --stack-name "$ALB_STACK_NAME" \
        --region "$REGION" >/dev/null 2>&1; then
        echo -e "${BLUE}[DESTROY] AlbBackendStack $ALB_STACK_NAME (${REGION}) -> remove next${NC}"
        cd "$CDK_DIR"
        AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
            npm run destroy -- "$ALB_STACK_NAME" -c "stackName=$STACK_NAME" -c createAlbBackend=true \
                -c "albEc2InstanceId=stub" -c "albEc2SecurityGroupId=stub" \
                -c "createCognito=true" --force || \
            echo -e "${YELLOW}[WARN] AlbBackend stack destroy returned non-zero; continuing${NC}"
    fi

    COGNITO_STACK_NAME="${STACK_NAME}-cognito"
    if aws cloudformation describe-stacks --stack-name "$COGNITO_STACK_NAME" \
        --region "$REGION" >/dev/null 2>&1; then
        echo -e "${BLUE}[DESTROY] CognitoOperatorStack $COGNITO_STACK_NAME -> remove last (after ALB Lambda is gone)${NC}"
        cd "$CDK_DIR"
        AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
            npm run destroy -- "$COGNITO_STACK_NAME" -c "stackName=$STACK_NAME" \
                -c "createCognito=true" --force || \
            echo -e "${YELLOW}[WARN] Cognito stack destroy returned non-zero; continuing${NC}"
    fi

    # Capture SG and EFS ids from CFN outputs BEFORE destroy - they are
    # unreadable once the stack is gone.
    DESTROY_SG_ID=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`SecurityGroupId`].OutputValue' \
        --output text 2>/dev/null)
    DESTROY_EFS_ID=$(aws cloudformation describe-stacks \
        --stack-name "$STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`EfsId`].OutputValue' \
        --output text 2>/dev/null)

    cd "$CDK_DIR"
    # Destroy the EC2 stack. The `-c stackName=...` is REQUIRED because the
    # CDK app keys its top-level stack name on this context value. Without
    # it, `npm run destroy -- storeai-validation-sae1` synthesizes the
    # default `neuron-code-server` stack, finds it not in CFN, and silently
    # exits 0 — leaving the real stack intact (Trn2 Spot still running).
    AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
        npm run destroy -- "$STACK_NAME" -c "stackName=$STACK_NAME" --force
    RC=$?

    # If the user also created an EFS stack via --create-efs, destroy it
    # last so the EC2 stack's NFS ingress is gone first. Best-effort: if
    # the stack does not exist, we just continue.
    EFS_STACK_NAME="${STACK_NAME}-efs"
    if aws cloudformation describe-stacks --stack-name "$EFS_STACK_NAME" \
        --region "$REGION" >/dev/null 2>&1; then
        echo -e "${BLUE}[DESTROY] EFS persistence stack ${EFS_STACK_NAME}${NC}"
        AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
            npm run destroy -- "$EFS_STACK_NAME" -c "stackName=$STACK_NAME" -c "createEfs=true" --force || \
            echo -e "${YELLOW}[WARN] EFS stack destroy returned non-zero${NC}"
    fi

    # Revoke the cross-SG NFS rule we added at deploy time.
    # CDK owns the instance security group and will delete it when the
    # stack is destroyed, but it does NOT own the EFS mount target SG.
    # Rules that reference the deleted group would otherwise linger. This
    # revoke is best-effort - failure to revoke does not fail destroy.
    if [[ -n "$DESTROY_SG_ID" ]] && [[ "$DESTROY_SG_ID" != "None" ]] && \
       [[ -n "$DESTROY_EFS_ID" ]] && [[ "$DESTROY_EFS_ID" != "None" ]] && \
       [[ "$DESTROY_EFS_ID" != "none" ]]; then
        echo ""
        echo -e "${BLUE}[EFS-SG] Post-destroy cleanup: revoking NFS ingress on EFS MT SG${NC}"
        manage_efs_mt_ingress revoke "$DESTROY_EFS_ID" "$DESTROY_SG_ID" "" "$REGION" || true
    fi

    exit $RC
fi

# Build CDK context parameters
CDK_PARAMS=()
CDK_PARAMS+=("-c" "stackName=$STACK_NAME")
if [[ -n "$PROJECT" ]]; then
    CDK_PARAMS+=("-c" "project=$PROJECT")
fi
if [[ -n "$PURPOSE" ]]; then
    CDK_PARAMS+=("-c" "purpose=$PURPOSE")
fi
if [[ "$USE_CAPACITY_BLOCK" == true ]]; then
    CDK_PARAMS+=("-c" "useCapacityBlock=true")

    # Resolve reservation id / subnet id from SSM Parameter Store if the
    # user did not pass them on the command line. `--slot NAME` selects
    # among multiple reservations; the default slot falls back to the
    # legacy flat layout so existing deployments keep working.
    if [[ "$CB_SLOT" == "default" ]]; then
        CB_RES_PATH="/capacity-block/${REGION}/reservation-id"
        CB_SUB_PATH="/capacity-block/${REGION}/subnet-id"
    else
        CB_RES_PATH="/capacity-block/${REGION}/slots/${CB_SLOT}/reservation-id"
        CB_SUB_PATH="/capacity-block/${REGION}/slots/${CB_SLOT}/subnet-id"
    fi

    if [[ -z "$CAPACITY_RESERVATION_ID" ]]; then
        echo -e "${BLUE}[FETCH] Reading Capacity Reservation id from SSM (slot=${CB_SLOT})...${NC}"
        CAPACITY_RESERVATION_ID=$(aws ssm get-parameter \
            --name "$CB_RES_PATH" \
            --region "$REGION" \
            --query 'Parameter.Value' \
            --output text 2>/dev/null)

        # For non-default slots, silently fall back to the legacy flat
        # key as a convenience only if nothing was found AND the slot
        # looks unset. Explicit named slots should not leak into default.
        if [[ -z "$CAPACITY_RESERVATION_ID" || "$CAPACITY_RESERVATION_ID" == "None" ]] \
           && [[ "$CB_SLOT" != "default" ]]; then
            echo -e "${YELLOW}  [WARN] Slot '${CB_SLOT}' not found under ${CB_RES_PATH}${NC}"
            CAPACITY_RESERVATION_ID=""
        fi

        if [[ -n "$CAPACITY_RESERVATION_ID" ]] && [[ "$CAPACITY_RESERVATION_ID" != "None" ]]; then
            echo "  Found: $CAPACITY_RESERVATION_ID"
        else
            echo -e "${YELLOW}  [WARN] Not found in Parameter Store${NC}"
        fi
    fi

    if [[ -z "$SUBNET_ID" ]]; then
        echo -e "${BLUE}[FETCH] Reading Subnet id from SSM (slot=${CB_SLOT})...${NC}"
        SUBNET_ID=$(aws ssm get-parameter \
            --name "$CB_SUB_PATH" \
            --region "$REGION" \
            --query 'Parameter.Value' \
            --output text 2>/dev/null)

        if [[ -n "$SUBNET_ID" ]] && [[ "$SUBNET_ID" != "None" ]]; then
            echo "  Found: $SUBNET_ID"
        else
            echo -e "${YELLOW}  [WARN] Not found in Parameter Store${NC}"
        fi
    fi

    if [[ -n "$CAPACITY_RESERVATION_ID" ]]; then
        CDK_PARAMS+=("-c" "capacityReservationId=$CAPACITY_RESERVATION_ID")
    fi
    if [[ -n "$SUBNET_ID" ]]; then
        CDK_PARAMS+=("-c" "subnetId=$SUBNET_ID")
    fi
fi

if [[ "$USE_SPOT" == true ]]; then
    CDK_PARAMS+=("-c" "useSpot=true")
    if [[ -n "$SPOT_MAX_PRICE" ]]; then
        CDK_PARAMS+=("-c" "spotMaxPrice=$SPOT_MAX_PRICE")
    fi
    if [[ -n "$SPOT_INTERRUPTION_BEHAVIOR" ]]; then
        CDK_PARAMS+=("-c" "spotInterruptionBehavior=$SPOT_INTERRUPTION_BEHAVIOR")
    fi
fi

# EFS handling:
#   --no-efs      -> pass efsId=none so the stack runs without EFS
#   --efs-id ID   -> pass it through
#   neither       -> fall back to config.json regions[REGION].defaultEfsId
if [[ "$NO_EFS" == true ]]; then
    CDK_PARAMS+=("-c" "efsId=none")
elif [[ -n "$EFS_ID" ]]; then
    CDK_PARAMS+=("-c" "efsId=$EFS_ID")
fi
if [[ -n "$EFS_SUBPATH" ]]; then
    CDK_PARAMS+=("-c" "efsSubpath=$EFS_SUBPATH")
fi

if [[ -n "$INSTANCE_TYPE" ]]; then
    CDK_PARAMS+=("-c" "instanceType=$INSTANCE_TYPE")
fi

if [[ -n "$VOLUME_SIZE" ]]; then
    CDK_PARAMS+=("-c" "volumeSize=$VOLUME_SIZE")
fi

if [[ "$INSTALL_CLAUDE_CODE" == true ]]; then
    CDK_PARAMS+=("-c" "installClaudeCode=true")
fi

echo -e "${BLUE}[BUILD] Compiling CDK app...${NC}"
cd "$CDK_DIR"
npm run build

# ----------------------------------------------------------------------
# Optional first phase: provision EFS via CDK as a separate stack
# ----------------------------------------------------------------------
# When --create-efs is set, deploy `<stackName>-efs` first, then read the
# resulting EfsId from CloudFormation outputs and feed it into the EC2
# stack via -c efsId=<fs-...>. This keeps the EC2 stack lifecycle decoupled
# from EFS — Spot interruption / re-deploy on the EC2 side does not touch
# the file system that holds compiled NEFF caches and HF model downloads.
if [[ "$CREATE_EFS" == true ]]; then
    EFS_STACK_NAME="${STACK_NAME}-efs"
    echo ""
    echo -e "${BLUE}[DEPLOY] EFS persistence stack ${EFS_STACK_NAME} (region: ${REGION})${NC}"

    EFS_CDK_PARAMS=("-c" "stackName=$STACK_NAME" "-c" "createEfs=true")
    if [[ -n "$PROJECT" ]]; then
        EFS_CDK_PARAMS+=("-c" "project=$PROJECT")
    fi
    if [[ -n "$PURPOSE" ]]; then
        EFS_CDK_PARAMS+=("-c" "purpose=$PURPOSE")
    fi

    aws_creds_refresh
    AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
        npm run deploy -- "$EFS_STACK_NAME" "${EFS_CDK_PARAMS[@]}" --require-approval never
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[NG] EFS stack deploy failed${NC}"
        exit 1
    fi

    EFS_ID=$(aws cloudformation describe-stacks \
        --stack-name "$EFS_STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`EfsId`].OutputValue' --output text)
    if [[ -z "$EFS_ID" ]] || [[ "$EFS_ID" == "None" ]]; then
        echo -e "${RED}[NG] EFS stack succeeded but EfsId output is empty${NC}"
        exit 1
    fi
    echo -e "${GREEN}[OK] EFS provisioned: ${EFS_ID}${NC}"

    # Inject the new EFS id into the EC2 stack's CDK params, replacing any
    # earlier --efs-id / --no-efs decisions for this run. We also disable
    # the NO_EFS flag so the downstream EC2 deploy path treats EFS as live.
    NO_EFS=false
    # Strip any previously appended efsId=... entries to keep the array
    # consistent if the user passed --efs-id <other> before --create-efs.
    NEW_PARAMS=()
    SKIP_NEXT=0
    for p in "${CDK_PARAMS[@]}"; do
        if [[ "$SKIP_NEXT" -eq 1 ]]; then
            SKIP_NEXT=0
            continue
        fi
        if [[ "$p" == "efsId="* ]]; then
            continue
        fi
        if [[ "$p" == "-c" ]] && [[ "$p" != "${CDK_PARAMS[${#CDK_PARAMS[@]}-1]}" ]]; then
            # Peek at the next entry; if it starts with efsId= drop the pair.
            idx=$((${#NEW_PARAMS[@]}))
            NEW_PARAMS+=("$p")
            continue
        fi
        NEW_PARAMS+=("$p")
    done
    CDK_PARAMS=("${NEW_PARAMS[@]}")
    CDK_PARAMS+=("-c" "efsId=$EFS_ID")
fi

echo ""
echo -e "${BLUE}[DEPLOY] Deploying CDK stack...${NC}"
aws_creds_refresh
AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" npm run deploy -- "$STACK_NAME" "${CDK_PARAMS[@]}" --require-approval never

if [[ $? -ne 0 ]]; then
    echo -e "${RED}[NG] CDK deploy failed${NC}"
    exit 1
fi

echo ""
echo -e "${GREEN}[OK] CDK deploy complete${NC}"

echo ""
echo -e "${BLUE}[INFO] Fetching stack information...${NC}"

INSTANCE_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
    --output text)

PUBLIC_DNS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`InstancePublicDnsName`].OutputValue' \
    --output text)

SG_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`SecurityGroupId`].OutputValue' \
    --output text 2>/dev/null)

STACK_EFS_ID=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs[?OutputKey==`EfsId`].OutputValue' \
    --output text 2>/dev/null)

# Resolve the password Secret ARN for THIS stack specifically so a parallel
# stack's secret is never shown by mistake.
SECRET_ARN=$(aws secretsmanager list-secrets \
    --region "$REGION" \
    --query "SecretList[?contains(Name, 'CodeServerPassword') && Tags[?Key=='aws:cloudformation:stack-name' && Value=='$STACK_NAME']].ARN | [0]" \
    --output text)

echo "Instance ID: $INSTANCE_ID"

# ------------------------------------------------------------------
# Automatically authorize NFS (2049) on the EFS mount target security
# group so /home/coder and /work can be mounted via EFS on this stack's
# instance. Idempotent - if the rule already exists we skip it. If EFS
# is disabled (EfsId output == 'none') this block does nothing.
# ------------------------------------------------------------------
if [[ -n "$SG_ID" ]] && [[ "$SG_ID" != "None" ]] && \
   [[ -n "$STACK_EFS_ID" ]] && [[ "$STACK_EFS_ID" != "None" ]] && \
   [[ "$STACK_EFS_ID" != "none" ]]; then
    echo ""
    echo -e "${BLUE}[EFS-SG] Authorizing NFS ingress on EFS mount target SG${NC}"
    echo "  EFS:   $STACK_EFS_ID"
    echo "  SG:    $SG_ID (stack: $STACK_NAME)"
    manage_efs_mt_ingress authorize "$STACK_EFS_ID" "$SG_ID" "$STACK_NAME NFS" "$REGION" || {
        echo -e "${YELLOW}[WARN] EFS mount target SG authorize failed${NC}"
        echo -e "${YELLOW}       NFS mount in setup-persistence may time out.${NC}"
    }
fi
echo "Public DNS: $PUBLIC_DNS"
echo "Secret ARN: $SECRET_ARN"

# Code-server setup via SSM Run Command
if [[ "$SKIP_SETUP" == false ]]; then
    echo ""
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}code-server setup${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo ""

    # Wait for the SSM agent to register and reach Online. Right after
    # instance boot it typically takes 2-3 minutes. setup-code-server.sh
    # dispatches SSM Run Commands, which fail with "Instances not in a
    # valid state" if the agent has not registered yet.
    echo -e "${BLUE}[CHECK] Waiting for SSM agent to come Online...${NC}"
    SSM_READY=false
    for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
        sleep 15
        PING=$(aws ssm describe-instance-information --region "$REGION" \
            --filters "Key=InstanceIds,Values=$INSTANCE_ID" \
            --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null)
        echo "    wait $i: SSM=${PING:-not-registered}"
        if [[ "$PING" == "Online" ]]; then
            SSM_READY=true
            break
        fi
    done
    # Arguments passed through to setup-code-server.sh
    SETUP_ARGS=(-i "$INSTANCE_ID" -r "$REGION" -s "$SECRET_ARN")
    if [[ "$NO_EFS" == true ]]; then
        SETUP_ARGS+=(--efs-id none)
    elif [[ -n "$EFS_ID" ]]; then
        SETUP_ARGS+=(--efs-id "$EFS_ID")
    fi
    if [[ -n "$EFS_SUBPATH" ]]; then
        SETUP_ARGS+=(--efs-subpath "$EFS_SUBPATH")
    fi
    if [[ "$INSTALL_CLAUDE_CODE" == true ]]; then
        SETUP_ARGS+=(--install-claude-code)
    fi
    SETUP_CMD="bash $SCRIPT_DIR/setup-code-server.sh ${SETUP_ARGS[*]}"

    if [[ "$SSM_READY" != true ]]; then
        echo -e "${YELLOW}[WARN] SSM agent did not come Online; skipping setup${NC}"
        echo "  Run manually:   $SETUP_CMD"
    else
        bash "$SCRIPT_DIR/setup-code-server.sh" "${SETUP_ARGS[@]}"

        if [[ $? -ne 0 ]]; then
            echo -e "${RED}[NG] code-server setup failed${NC}"
            echo -e "${YELLOW}Re-run manually:${NC}"
            echo "  $SETUP_CMD"
            exit 1
        fi
    fi
else
    echo ""
    echo -e "${YELLOW}[INFO] Skipping code-server setup (--skip-setup)${NC}"
    echo "Run it manually with:"
    echo "  bash $SCRIPT_DIR/setup-code-server.sh -i $INSTANCE_ID -r $REGION -s $SECRET_ARN ${EFS_SUBPATH:+--efs-subpath $EFS_SUBPATH}"
fi

# ----------------------------------------------------------------------
# Phase C: CognitoOperatorStack (UserPool + Hosted UI)
# ----------------------------------------------------------------------
# Per ADR-011 the OAuth Lambda lives in the ALB stack and references the
# Cognito UserPool + Hosted UI domain at synth time, so Cognito MUST be
# deployed before AlbBackendStack. Cognito UserPool creation is fast
# (<1 min) and the Hosted UI domain prefix must be globally unique inside
# the region.
if [[ "$CREATE_COGNITO" == true ]]; then
    COGNITO_STACK_NAME="${STACK_NAME}-cognito"
    echo ""
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}[DEPLOY] CognitoOperatorStack ${COGNITO_STACK_NAME}${NC}"
    echo -e "${BLUE}=========================================${NC}"

    # ----------------------------------------------------------------
    # Optional: stage operator password in Secrets Manager (ADR-013)
    # ----------------------------------------------------------------
    # We deliberately write the password to a Secrets Manager secret
    # OUTSIDE the CFN stack, then pass only the ARN to CDK as a context
    # value. The Custom Resource Lambda inside the Cognito stack reads
    # the SecretString at runtime via grant_read. This keeps the
    # password out of cdk.out, the CFN template, and any drift diffs.
    #
    # Validation rules (mirrors the UserPool password policy):
    #   - email must be RFC 5321-ish (has '@', no spaces) — minimal sanity
    #   - password must be >=12 chars and contain lower/upper/digit
    if [[ -n "$OPERATOR_PASSWORD" ]] && [[ -n "$OPERATOR_PASSWORD_SECRET_ARN" ]]; then
        echo -e "${RED}[NG] --operator-password and --operator-password-secret-arn are mutually exclusive${NC}"
        exit 1
    fi
    if [[ -n "$OPERATOR_EMAIL" ]] || [[ -n "$OPERATOR_PASSWORD" ]] || [[ -n "$OPERATOR_PASSWORD_SECRET_ARN" ]]; then
        if [[ -z "$OPERATOR_EMAIL" ]]; then
            echo -e "${RED}[NG] --operator-password / --operator-password-secret-arn require --operator-email${NC}"
            exit 1
        fi
        if [[ -z "$OPERATOR_PASSWORD" ]] && [[ -z "$OPERATOR_PASSWORD_SECRET_ARN" ]]; then
            echo -e "${RED}[NG] --operator-email requires --operator-password or --operator-password-secret-arn${NC}"
            exit 1
        fi
        if [[ ! "$OPERATOR_EMAIL" =~ @ ]] || [[ "$OPERATOR_EMAIL" =~ [[:space:]] ]]; then
            echo -e "${RED}[NG] --operator-email looks malformed: $OPERATOR_EMAIL${NC}"
            exit 1
        fi
        if [[ -n "$OPERATOR_PASSWORD" ]]; then
            OPERATOR_PWLEN=${#OPERATOR_PASSWORD}
            if (( OPERATOR_PWLEN < 12 )); then
                echo -e "${RED}[NG] --operator-password must be at least 12 chars (Cognito policy)${NC}"
                exit 1
            fi
            if [[ ! "$OPERATOR_PASSWORD" =~ [a-z] ]] || \
               [[ ! "$OPERATOR_PASSWORD" =~ [A-Z] ]] || \
               [[ ! "$OPERATOR_PASSWORD" =~ [0-9] ]]; then
                echo -e "${RED}[NG] --operator-password must contain lower, upper, and digit (Cognito policy)${NC}"
                exit 1
            fi
        fi
    fi

    if [[ -n "$OPERATOR_EMAIL" ]] && [[ -n "$OPERATOR_PASSWORD" ]]; then
        OP_SECRET_NAME="${STACK_NAME}-operator-password"
        echo -e "${BLUE}[BOOT] Staging operator password in Secrets Manager (${OP_SECRET_NAME})${NC}"

        EXISTING_ARN=$(aws secretsmanager describe-secret \
            --secret-id "$OP_SECRET_NAME" \
            --region "$REGION" \
            --query 'ARN' --output text 2>/dev/null || true)

        if [[ -n "$EXISTING_ARN" ]] && [[ "$EXISTING_ARN" != "None" ]]; then
            aws secretsmanager put-secret-value \
                --secret-id "$EXISTING_ARN" \
                --region "$REGION" \
                --secret-string "$OPERATOR_PASSWORD" \
                --output json > /dev/null
            OPERATOR_PASSWORD_SECRET_ARN="$EXISTING_ARN"
            echo "  Updated existing secret: $OPERATOR_PASSWORD_SECRET_ARN"
        else
            CREATED=$(aws secretsmanager create-secret \
                --name "$OP_SECRET_NAME" \
                --description "Cognito operator password for stack $STACK_NAME (ADR-013)" \
                --secret-string "$OPERATOR_PASSWORD" \
                --region "$REGION" \
                --output json)
            OPERATOR_PASSWORD_SECRET_ARN=$(echo "$CREATED" | jq -r '.ARN')
            echo "  Created new secret:      $OPERATOR_PASSWORD_SECRET_ARN"
        fi
        # Scrub the plaintext from this shell session ASAP. The variable
        # was only needed to seed Secrets Manager; from here on the CDK
        # path uses the ARN exclusively.
        OPERATOR_PASSWORD=""
    fi

    COGNITO_CDK_PARAMS=(
        "-c" "stackName=$STACK_NAME"
        "-c" "createCognito=true"
    )
    if [[ -n "$COGNITO_DOMAIN_PREFIX" ]]; then
        COGNITO_CDK_PARAMS+=("-c" "cognitoDomainPrefix=$COGNITO_DOMAIN_PREFIX")
    fi
    if [[ -n "$OPERATOR_EMAIL" ]]; then
        COGNITO_CDK_PARAMS+=("-c" "operatorEmail=$OPERATOR_EMAIL")
    fi
    if [[ -n "$OPERATOR_PASSWORD_SECRET_ARN" ]]; then
        COGNITO_CDK_PARAMS+=("-c" "operatorPasswordSecretArn=$OPERATOR_PASSWORD_SECRET_ARN")
    fi
    if [[ -n "$PROJECT" ]]; then
        COGNITO_CDK_PARAMS+=("-c" "project=$PROJECT")
    fi
    if [[ -n "$PURPOSE" ]]; then
        COGNITO_CDK_PARAMS+=("-c" "purpose=$PURPOSE")
    fi

    cd "$CDK_DIR"
    aws_creds_refresh
    AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
        npm run deploy -- "$COGNITO_STACK_NAME" "${COGNITO_CDK_PARAMS[@]}" --require-approval never
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[NG] CognitoOperatorStack deploy failed${NC}"
        exit 1
    fi
    echo -e "${GREEN}[OK] CognitoOperatorStack deployed${NC}"
fi

# ----------------------------------------------------------------------
# Phase B: deploy AlbBackendStack alongside the EC2 stack
# ----------------------------------------------------------------------
# Internal ALB + N target groups (code-server + 4 app routes + 1 OAuth
# Lambda TG). All app/code-server TGs are wired to the EC2 instance just
# deployed; the OAuth Lambda lives inside this stack (ADR-011) and is
# exposed only via the ALB Lambda Target Group at /oauth/*. The ALB SG
# starts with zero ingress; the CloudFront frontend stack (Phase D) is
# the only caller that opens it.
#
# Cognito MUST be in the same synth pass: the OAuth Lambda env consumes
# UserPool id + Hosted UI FQDN at synth time, so we pass the same
# createCognito flag here as well.
#
# Inputs (passed via context to bin/app.ts):
#   - albEc2InstanceId       = $INSTANCE_ID
#   - albEc2SecurityGroupId  = $SG_ID
# Both come from the EC2 stack outputs we already fetched above.
if [[ "$CREATE_ALB_BACKEND" == true ]]; then
    if [[ "$CREATE_COGNITO" != true ]]; then
        echo -e "${RED}[NG] --create-alb-backend requires --create-cognito in the same run (ADR-011)${NC}"
        exit 1
    fi
    if [[ -z "$INSTANCE_ID" ]] || [[ "$INSTANCE_ID" == "None" ]]; then
        echo -e "${RED}[NG] EC2 stack did not export InstanceId; cannot wire ALB backend${NC}"
        exit 1
    fi
    if [[ -z "$SG_ID" ]] || [[ "$SG_ID" == "None" ]]; then
        echo -e "${RED}[NG] EC2 stack did not export SecurityGroupId; cannot wire ALB backend${NC}"
        exit 1
    fi

    ALB_STACK_NAME="${STACK_NAME}-alb"
    echo ""
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}[DEPLOY] AlbBackendStack ${ALB_STACK_NAME} (region: ${REGION})${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo "  EC2 instance: $INSTANCE_ID"
    echo "  EC2 SG:       $SG_ID"

    ALB_CDK_PARAMS=(
        "-c" "stackName=$STACK_NAME"
        "-c" "createAlbBackend=true"
        "-c" "albEc2InstanceId=$INSTANCE_ID"
        "-c" "albEc2SecurityGroupId=$SG_ID"
        "-c" "createCognito=true"
    )
    if [[ -n "$COGNITO_DOMAIN_PREFIX" ]]; then
        ALB_CDK_PARAMS+=("-c" "cognitoDomainPrefix=$COGNITO_DOMAIN_PREFIX")
    fi
    if [[ -n "$OPERATOR_EMAIL" ]]; then
        ALB_CDK_PARAMS+=("-c" "operatorEmail=$OPERATOR_EMAIL")
    fi
    if [[ -n "$OPERATOR_PASSWORD_SECRET_ARN" ]]; then
        ALB_CDK_PARAMS+=("-c" "operatorPasswordSecretArn=$OPERATOR_PASSWORD_SECRET_ARN")
    fi
    if [[ -n "$PROJECT" ]]; then
        ALB_CDK_PARAMS+=("-c" "project=$PROJECT")
    fi
    if [[ -n "$PURPOSE" ]]; then
        ALB_CDK_PARAMS+=("-c" "purpose=$PURPOSE")
    fi

    cd "$CDK_DIR"
    aws_creds_refresh
    AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
        npm run deploy -- "$ALB_STACK_NAME" "${ALB_CDK_PARAMS[@]}" --require-approval never

    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[NG] AlbBackendStack deploy failed${NC}"
        echo -e "${YELLOW}    The EC2 stack remains intact (SSM port forwarding still works).${NC}"
        exit 1
    fi
    echo -e "${GREEN}[OK] AlbBackendStack deployed${NC}"

    ALB_DNS=$(aws cloudformation describe-stacks --stack-name "$ALB_STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`AlbDnsName`].OutputValue' --output text 2>/dev/null)
    ALB_SG=$(aws cloudformation describe-stacks --stack-name "$ALB_STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`AlbSecurityGroupId`].OutputValue' --output text 2>/dev/null)
    ALB_OV_ARN=$(aws cloudformation describe-stacks --stack-name "$ALB_STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`OriginVerifySecretArn`].OutputValue' --output text 2>/dev/null)
    OAUTH_LAMBDA_ARN=$(aws cloudformation describe-stacks --stack-name "$ALB_STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`OAuthLambdaArn`].OutputValue' --output text 2>/dev/null)

    echo "  Internal ALB DNS: $ALB_DNS"
    echo "  ALB SG:           $ALB_SG  (no inbound rules until Phase D)"
    echo "  Origin secret:    $ALB_OV_ARN"
    echo "  OAuth Lambda:     $OAUTH_LAMBDA_ARN"
fi

# ----------------------------------------------------------------------
# Phase D: CloudFrontFrontendStack (ADR-005 frontend)
# ----------------------------------------------------------------------
# Hard-requires Phase B and C from THIS run because bin/app.ts hands
# the L2 references through directly. We always pass the same context
# flags we used for B and C so cdk synth wires them up identically.
if [[ "$CREATE_CLOUDFRONT_FRONTEND" == true ]]; then
    if [[ "$CREATE_ALB_BACKEND" != true ]]; then
        echo -e "${RED}[NG] --create-cloudfront-frontend requires --create-alb-backend in the same run${NC}"
        exit 1
    fi
    if [[ "$CREATE_COGNITO" != true ]]; then
        echo -e "${RED}[NG] --create-cloudfront-frontend requires --create-cognito in the same run${NC}"
        exit 1
    fi

    FRONTEND_STACK_NAME="${STACK_NAME}-frontend"
    echo ""
    echo -e "${BLUE}=========================================${NC}"
    echo -e "${BLUE}[DEPLOY] CloudFrontFrontendStack ${FRONTEND_STACK_NAME}${NC}"
    echo -e "${BLUE}=========================================${NC}"
    echo "  ALB instance: $INSTANCE_ID"
    echo "  ALB SG:       $SG_ID"

    FRONTEND_CDK_PARAMS=(
        "-c" "stackName=$STACK_NAME"
        "-c" "createAlbBackend=true"
        "-c" "albEc2InstanceId=$INSTANCE_ID"
        "-c" "albEc2SecurityGroupId=$SG_ID"
        "-c" "createCognito=true"
        "-c" "createCloudFrontFrontend=true"
    )
    if [[ -n "$COGNITO_DOMAIN_PREFIX" ]]; then
        FRONTEND_CDK_PARAMS+=("-c" "cognitoDomainPrefix=$COGNITO_DOMAIN_PREFIX")
    fi
    if [[ -n "$OPERATOR_EMAIL" ]]; then
        FRONTEND_CDK_PARAMS+=("-c" "operatorEmail=$OPERATOR_EMAIL")
    fi
    if [[ -n "$OPERATOR_PASSWORD_SECRET_ARN" ]]; then
        FRONTEND_CDK_PARAMS+=("-c" "operatorPasswordSecretArn=$OPERATOR_PASSWORD_SECRET_ARN")
    fi
    if [[ -n "$PROJECT" ]]; then
        FRONTEND_CDK_PARAMS+=("-c" "project=$PROJECT")
    fi
    if [[ -n "$PURPOSE" ]]; then
        FRONTEND_CDK_PARAMS+=("-c" "purpose=$PURPOSE")
    fi

    cd "$CDK_DIR"
    aws_creds_refresh
    AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
        npm run deploy -- "$FRONTEND_STACK_NAME" "${FRONTEND_CDK_PARAMS[@]}" --require-approval never
    if [[ $? -ne 0 ]]; then
        echo -e "${RED}[NG] CloudFrontFrontendStack deploy failed${NC}"
        echo -e "${YELLOW}    The EC2 / ALB / Cognito stacks remain intact.${NC}"
        exit 1
    fi
    echo -e "${GREEN}[OK] CloudFrontFrontendStack deployed${NC}"

    CF_DOMAIN=$(aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDomainName`].OutputValue' --output text 2>/dev/null)
    CF_DIST_ID=$(aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDistributionId`].OutputValue' --output text 2>/dev/null)
    CF_CALLBACK=$(aws cloudformation describe-stacks --stack-name "$FRONTEND_STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs[?OutputKey==`CognitoCallbackUrl`].OutputValue' --output text 2>/dev/null)
    echo "  CloudFront URL:  https://${CF_DOMAIN}/"
    echo "  Distribution:    $CF_DIST_ID"
    echo "  OAuth callback:  $CF_CALLBACK"
    if [[ -n "$OPERATOR_EMAIL" ]]; then
        echo ""
        echo -e "${GREEN}  [OPERATOR] Hosted UI sign-in is ready:${NC}"
        echo "    URL:   https://${CF_DOMAIN}/"
        echo "    Email: $OPERATOR_EMAIL"
        echo "    (password = SecretString of $OPERATOR_PASSWORD_SECRET_ARN)"
    fi
fi

# Final summary
echo ""
echo -e "${GREEN}=========================================${NC}"
echo -e "${GREEN}[DONE] deploy complete${NC}"
echo -e "${GREEN}=========================================${NC}"
echo ""
echo "[INFO] Connection info:"
echo "  Instance ID: $INSTANCE_ID"
echo "  Region:      $REGION"
echo ""
echo "[ACCESS] SSM port forwarding, 3 steps (run these locally):"
echo ""
echo "  # ==== Step 1a (recommended): let this script open the tunnel ===="
echo "  ${PROFILE_PREFIX}bash $0 --port-forward --stack-name $STACK_NAME -p 8080:80 -r $REGION"
echo ""
echo "  # ==== Step 1b (raw equivalent): call aws CLI directly ===="
echo "  ${PROFILE_PREFIX}aws ssm start-session --target $INSTANCE_ID --region $REGION \\"
echo "    --document-name AWS-StartPortForwardingSession \\"
echo "    --parameters '{\"portNumber\":[\"80\"],\"localPortNumber\":[\"8080\"]}'"
echo ""
echo "  # ==== Step 2: open http://localhost:8080 in your browser ===="
echo ""
echo "  # ==== Step 3: fetch the login password ===="
echo "  ${PROFILE_PREFIX}aws secretsmanager get-secret-value --secret-id $SECRET_ARN --region $REGION --query 'SecretString' --output text"
# Print the resolved password inline (useful when multiple stacks coexist).
DEPLOY_PASSWORD=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region "$REGION" --query 'SecretString' --output text 2>/dev/null)
if [[ -n "$DEPLOY_PASSWORD" ]] && [[ "$DEPLOY_PASSWORD" != "None" ]]; then
    echo ""
    echo -e "  ${GREEN}[$STACK_NAME] password = $DEPLOY_PASSWORD${NC}"
fi
echo ""
echo "[CONN] SSM shell session (debugging):"
echo "  ${PROFILE_PREFIX}aws ssm start-session --target $INSTANCE_ID --region $REGION"
echo ""
echo "[NOTE] External HTTP access is intentionally disabled. The security"
echo "       group has no ingress rules; reach code-server only through"
echo "       SSM Session Manager port forwarding as shown above."
echo ""

# ----------------------------------------------------------------------
# Browser-access frontend (Cognito Hosted UI + CloudFront) — wired in
# ----------------------------------------------------------------------
# Use --create-cognito + --create-cloudfront-frontend (and the prior
# --create-alb-backend) to deploy the ADR-005 frontend in one shot:
#
#   bash deploy.sh -r <region> --use-spot --spot-interruption-behavior stop \
#       --stack-name neuron-ws \
#       --create-alb-backend --create-cognito --create-cloudfront-frontend
#
# Output prints the public CloudFront URL. Operator users are added
# out-of-band via aws cognito-idp admin-create-user (selfSignUp is off).

echo -e "${GREEN}=========================================${NC}"
