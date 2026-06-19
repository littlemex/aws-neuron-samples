#!/bin/bash
# Code Server setup script (wrapper around the pipeline runner)

set -e

# Usage help
usage() {
    cat << EOF
Code Server Setup Script

Usage: $0 [OPTIONS]

Options:
    -i, --instance-id ID            Target EC2 instance ID (required)
    -r, --region REGION             AWS region (no default; honours AWS_DEFAULT_REGION / AWS_REGION env vars)
    -u, --user USERNAME             Code Server username (default: coder)
    -p, --password PASSWORD         Code Server password (if omitted, retrieved from Secrets Manager)
    -s, --secret-arn ARN            Secrets Manager ARN (for automatic password retrieval)
    -d, --home-dir DIR              Home directory (default: /work)
    --internal-port PORT            Code Server internal port (default: 8080)
    --nginx-port PORT               nginx external port (default: 80)
    --efs-id ID                     EFS file system ID
    --efs-subpath PATH              Subpath within EFS (default: /neuron-workspace)
                                    For multi-instance parallel use, specify a unique path per instance
                                    e.g. /neuron-workspace/manual, /neuron-workspace/experiment
    --start-from TASK_ID            Informational only; use 'run-pipeline rerun --from <id>' for
                                    fine-grained resume control with the YAML pipeline runner.
    --clean-state                   Informational only; use 'run-pipeline run --force-all' instead.
    --dry-run                       Display pipeline plan without executing (passed to run-pipeline).
    --reboot                        Reboot the instance after setup completes
    --install-claude-code           Opt-in: install Anthropic Claude Code CLI and
                                    neuron-agentic-development agents/skills into
                                    ~/.claude for the code-server user.
    --use-pipeline-runner           Accepted for backward compatibility; YAML pipeline runner is
                                    always used and this flag has no effect.
    -h, --help                      Show this help message

Examples:
    # Basic usage
    $0 -i i-1234567890abcdef0

    # Retrieve password from Secrets Manager
    $0 -i i-1234567890abcdef0 -s arn:aws:secretsmanager:...

    # Specify password directly
    $0 -i i-1234567890abcdef0 -p MySecurePassword123

    # Reboot after setup
    $0 -i i-1234567890abcdef0 --reboot
EOF
}

# Default values. REGION falls through to the operator's environment so a
# fresh shell does not silently target sa-east-1 (the previous default
# left over from the P9 dev environment).
INSTANCE_ID=""
REGION="${AWS_DEFAULT_REGION:-${AWS_REGION:-}}"
USER="coder"
PASSWORD=""
SECRET_ARN=""
HOME_DIR="/work"
INTERNAL_PORT="8080"
NGINX_PORT="80"
EFS_ID=""
EFS_SUBPATH=""
START_FROM=""
CLEAN_STATE=false
DRY_RUN=false
REBOOT=false
INSTALL_CLAUDE_CODE=false
# Accepted for backward compatibility; YAML pipeline runner is always used.
USE_PIPELINE_RUNNER="${USE_PIPELINE_RUNNER:-true}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -i|--instance-id)
            INSTANCE_ID="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -u|--user)
            USER="$2"
            shift 2
            ;;
        -p|--password)
            PASSWORD="$2"
            shift 2
            ;;
        -s|--secret-arn)
            SECRET_ARN="$2"
            shift 2
            ;;
        -d|--home-dir)
            HOME_DIR="$2"
            shift 2
            ;;
        --internal-port)
            INTERNAL_PORT="$2"
            shift 2
            ;;
        --nginx-port)
            NGINX_PORT="$2"
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
        --start-from)
            START_FROM="$2"
            shift 2
            ;;
        --clean-state)
            CLEAN_STATE=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --reboot)
            REBOOT=true
            shift
            ;;
        --install-claude-code)
            INSTALL_CLAUDE_CODE=true
            shift
            ;;
        --use-pipeline-runner)
            USE_PIPELINE_RUNNER=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Error: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

# Required parameter check
if [[ -z "$INSTANCE_ID" ]]; then
    echo "Error: Instance ID is required (-i option)"
    usage
    exit 1
fi
if [[ -z "$REGION" ]]; then
    echo "Error: AWS region is required (-r/--region or AWS_REGION/AWS_DEFAULT_REGION env var)"
    usage
    exit 1
fi

echo "========================================="
echo "Code Server Setup"
echo "========================================="
echo "Instance ID:       $INSTANCE_ID"
echo "Region:            $REGION"
echo "User:              $USER"
echo "Home Directory:    $HOME_DIR"
echo "Internal Port:     $INTERNAL_PORT"
echo "External Port (nginx): $NGINX_PORT"
echo "========================================="

# Retrieve password if not provided
if [[ -z "$PASSWORD" ]]; then
    if [[ -n "$SECRET_ARN" ]]; then
        echo "📦 Retrieving password from Secrets Manager..."
        PASSWORD=$(aws secretsmanager get-secret-value \
            --secret-id "$SECRET_ARN" \
            --region "$REGION" \
            --query 'SecretString' \
            --output text)
        echo "✅ Password retrieved successfully"
    else
        echo "⚠️  Warning: No password specified. Generating a random password."
        PASSWORD=$(openssl rand -base64 12)
        echo "🔑 Generated password: $PASSWORD"
    fi
fi

# Get script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

# Variable definitions passed to the pipeline runner as -v KEY=VALUE pairs.
# EFS_ID / EFS_SUBPATH override the YAML defaults when provided.
# INSTALL_CLAUDE_CODE is forwarded so pipeline tasks can gate on it.
VARS_BASE=$(cat << EOF
{
    "AWS_REGION": "$REGION",
    "USER": "$USER",
    "PASSWORD": "$PASSWORD",
    "HOME_DIR": "$HOME_DIR",
    "INTERNAL_PORT": "$INTERNAL_PORT",
    "NGINX_PORT": "$NGINX_PORT"
}
EOF
)
VARIABLES_JSON="$VARS_BASE"
if [[ -n "$EFS_ID" ]]; then
    VARIABLES_JSON=$(echo "$VARIABLES_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["EFS_ID"]="'"$EFS_ID"'"; print(json.dumps(d))')
fi
if [[ -n "$EFS_SUBPATH" ]]; then
    VARIABLES_JSON=$(echo "$VARIABLES_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["EFS_SUBPATH"]="'"$EFS_SUBPATH"'"; print(json.dumps(d))')
fi
# Pass INSTALL_CLAUDE_CODE through so pipeline tasks gated on it
# (e.g. 18-install-claude-code) can decide at runtime whether to run.
INSTALL_CLAUDE_CODE_VAL=$([[ "$INSTALL_CLAUDE_CODE" == true ]] && echo "yes" || echo "no")
VARIABLES_JSON=$(echo "$VARIABLES_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["INSTALL_CLAUDE_CODE"]="'"$INSTALL_CLAUDE_CODE_VAL"'"; print(json.dumps(d))')

# Transfer setup-persistence.sh to the instance (called by pipeline task 00-setup-persistence).
# Encode with base64 and place in /tmp via SSM Run Command.
PERSIST_SH="$SCRIPT_DIR/setup-persistence.sh"
if [[ -f "$PERSIST_SH" ]]; then
    echo "==> Uploading setup-persistence.sh to instance (/tmp/setup-persistence-full.sh)"
    PERSIST_B64=$(base64 < "$PERSIST_SH" | tr -d '\n')
    UPLOAD_ID=$(aws ssm send-command --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters "commands=[\"bash -c \\\"echo '${PERSIST_B64}' | base64 -d > /tmp/setup-persistence-full.sh && chmod +x /tmp/setup-persistence-full.sh && echo 'setup-persistence-full.sh uploaded: '\$(wc -c < /tmp/setup-persistence-full.sh)' bytes'\\\"\"]" \
        --query 'Command.CommandId' --output text 2>/dev/null)
    # Wait for completion
    for i in 1 2 3 4; do
        sleep 5
        S=$(aws ssm get-command-invocation --region "$REGION" --command-id "$UPLOAD_ID" --instance-id "$INSTANCE_ID" --query 'Status' --output text 2>/dev/null)
        [[ "$S" == "Success" || "$S" == "Failed" ]] && break
    done
    if [[ "$S" == "Success" ]]; then
        echo "    [OK] setup-persistence.sh uploaded"
    else
        echo "    [WARN] setup-persistence.sh upload failed, tasks 00-setup-persistence may skip"
    fi
fi

# Dispatch through the YAML pipeline runner (the only supported path).
REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
DISPATCH_HELPER="$REPO_ROOT/tools/pipeline-runner/lib-sh/dispatch.sh"
if [[ ! -f "$DISPATCH_HELPER" ]]; then
    echo "Error: dispatch helper missing at $DISPATCH_HELPER"
    exit 1
fi
export REPO_ROOT
# shellcheck disable=SC1090
source "$DISPATCH_HELPER"

PIPELINE_NAME="code-server-setup"
NEW_YML="$PROJECT_DIR/pipelines/code-server-setup/code-server-setup.yml"

if [[ -n "$START_FROM" || "$CLEAN_STATE" == "true" || "$DRY_RUN" == "true" ]]; then
    echo "[INFO] --start-from / --clean-state / --dry-run: use 'run-pipeline rerun --from <id>' / '--force-all' / '--dry-run' against $NEW_YML for fine control."
fi

pipeline_dispatch "$INSTANCE_ID" "$REGION" "" "$NEW_YML" "$VARIABLES_JSON" "$PIPELINE_NAME"

# Execution result
if [[ $? -eq 0 ]]; then
    echo ""
    echo "========================================="
    echo "🎉 Code Server setup complete!"
    echo "========================================="

    # Retrieve instance information
    PUBLIC_DNS=$(aws ec2 describe-instances \
        --instance-ids "$INSTANCE_ID" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].PublicDnsName' \
        --output text 2>/dev/null || echo "N/A")

    echo ""
    echo "🌐 Code Server URL:"
    if [[ "$PUBLIC_DNS" != "N/A" && -n "$PUBLIC_DNS" ]]; then
        echo "  http://$PUBLIC_DNS:$NGINX_PORT"
    else
        echo "  http://[YOUR_INSTANCE_IP]:$NGINX_PORT"
    fi
    echo ""
    echo "🔑 Password:"
    echo "  $PASSWORD"
    echo ""
    echo "ℹ️  Architecture:"
    echo "  Code Server: port $INTERNAL_PORT"
    echo "  nginx proxy: port $NGINX_PORT -> $INTERNAL_PORT"
    echo ""
    echo "🔌 SSM connection:"
    echo "  aws ssm start-session --target $INSTANCE_ID --region $REGION"
    echo ""
    echo "========================================="

    # Reboot handling
    if [[ "$REBOOT" == true ]]; then
        echo ""
        echo "🔄 Rebooting the instance..."
        echo ""
        aws ec2 reboot-instances \
            --instance-ids "$INSTANCE_ID" \
            --region "$REGION"

        if [[ $? -eq 0 ]]; then
            echo "✅ Reboot initiated"
            echo ""
            echo "⏳ Check instance status:"
            echo "  aws ec2 describe-instance-status --instance-ids $INSTANCE_ID --region $REGION"
            echo ""
            echo "⚠️  Note: It may take a few minutes for Code Server to restart after reboot"
        else
            echo "❌ Failed to initiate reboot"
            exit 1
        fi
    fi
else
    echo ""
    echo "❌ Setup failed"
    echo ""
    echo "To resume:"
    echo "  $0 -i $INSTANCE_ID -r $REGION [OPTIONS] --start-from <TASK_ID>"
    echo ""
    exit 1
fi
