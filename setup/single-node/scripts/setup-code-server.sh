#!/bin/bash
# Code Server setup script (wrapper around the task runner)

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
    --efs-id ID                     EFS file system ID (uses default from tasks JSON if not specified)
    --efs-subpath PATH              Subpath within EFS (default: /neuron-workspace)
                                    For multi-instance parallel use, specify a unique path per instance
                                    e.g. /neuron-workspace/manual, /neuron-workspace/experiment
    --start-from TASK_ID            Resume from the specified task ID
    --clean-state                   Clear state file and run from the beginning
    --dry-run                       Display tasks without actually executing them
    --reboot                        Reboot the instance after setup completes
    --install-claude-code           Opt-in: install Anthropic Claude Code CLI and
                                    neuron-agentic-development agents/skills into
                                    ~/.claude for the code-server user.
    --use-pipeline-runner           Dispatch through tools/pipeline-runner instead of
                                    the legacy run-tasks.sh.
    -h, --help                      Show this help message

Examples:
    # Basic usage
    $0 -i i-1234567890abcdef0

    # Retrieve password from Secrets Manager
    $0 -i i-1234567890abcdef0 -s arn:aws:secretsmanager:...

    # Specify password directly
    $0 -i i-1234567890abcdef0 -p MySecurePassword123

    # Resume from a specific task
    $0 -i i-1234567890abcdef0 --start-from 09-install-code-server

    # Dry run (preview what will be executed)
    $0 -i i-1234567890abcdef0 --dry-run

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
# When true, dispatch through tools/pipeline-runner; when false, the
# historical run-tasks.sh path is used. Same flag name as the other
# callers so operators can pass the same value top-down.
USE_PIPELINE_RUNNER="${USE_PIPELINE_RUNNER:-false}"

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
TASK_FILE="$PROJECT_DIR/tasks/code-server-setup.json"

# Check if task file exists
if [[ ! -f "$TASK_FILE" ]]; then
    echo "❌ Error: Task definition file not found: $TASK_FILE"
    exit 1
fi

# Variable definitions (JSON format)
# If --efs-id / --efs-subpath are specified, they override the defaults in tasks JSON.
# If not specified, the values from the variables section of tasks/code-server-setup.json are used.
# For multi-instance parallel use, always specify a unique --efs-subpath per instance (e.g. /neuron-workspace/manual).
VARS_BASE=$(cat << EOF
{
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
# Pass INSTALL_CLAUDE_CODE through so tasks gated on it (for example
# 18-install-claude-code) can decide at runtime whether to run.
INSTALL_CLAUDE_CODE_VAL=$([[ "$INSTALL_CLAUDE_CODE" == true ]] && echo "yes" || echo "no")
VARIABLES_JSON=$(echo "$VARIABLES_JSON" | python3 -c 'import json,sys; d=json.load(sys.stdin); d["INSTALL_CLAUDE_CODE"]="'"$INSTALL_CLAUDE_CODE_VAL"'"; print(json.dumps(d))')

# Transfer setup-persistence.sh to the instance (called by tasks/00-setup-persistence)
# Encode with base64 and place in /tmp via SSM with sudo
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

# Dispatch through the new pipeline-runner when --use-pipeline-runner is
# set; otherwise fall back to the legacy run-tasks.sh. The dispatch helper
# encapsulates the choice so this wrapper does not need two code paths.
REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
DISPATCH_HELPER="$REPO_ROOT/tools/pipeline-runner/lib-sh/dispatch.sh"
if [[ ! -f "$DISPATCH_HELPER" ]]; then
    echo "Error: dispatch helper missing at $DISPATCH_HELPER"
    exit 1
fi
export REPO_ROOT
# shellcheck disable=SC1090
source "$DISPATCH_HELPER"

# Map tasks/code-server-setup.json -> pipelines/code-server-setup/code-server-setup.yml.
PIPELINE_NAME="$(basename "$TASK_FILE" .json)"
NEW_YML="$PROJECT_DIR/pipelines/${PIPELINE_NAME}/${PIPELINE_NAME}.yml"

# The legacy runner accepted --start-from and --clean-state for resume
# semantics; the new runner offers `rerun --from <task-id>` and
# `--force-all`. We keep the wrapper minimal and only respect
# --start-from when on the legacy path; on the new path we inform the
# operator and proceed without it (this is documented in the README).
if [[ "$USE_PIPELINE_RUNNER" == "true" ]]; then
    if [[ -n "$START_FROM" || "$CLEAN_STATE" == "true" || "$DRY_RUN" == "true" ]]; then
        echo "[INFO] --start-from / --clean-state / --dry-run on the new runner: use 'rerun --from <id>' / '--force-all' / '--dry-run' against $NEW_YML directly for fine control."
    fi
fi

if [[ "$DRY_RUN" == "true" && "$USE_PIPELINE_RUNNER" != "true" ]]; then
    # Preserve the legacy --dry-run behaviour when going through the old runner.
    bash "$SCRIPT_DIR/run-tasks.sh" -i "$INSTANCE_ID" -r "$REGION" -f "$TASK_FILE" -v "$VARIABLES_JSON" --dry-run
elif [[ "$USE_PIPELINE_RUNNER" != "true" && (-n "$START_FROM" || "$CLEAN_STATE" == "true") ]]; then
    # Legacy resume / clean-state forms: keep using run-tasks.sh directly.
    RUN_TASKS_ARGS=(
        -i "$INSTANCE_ID" -r "$REGION" -f "$TASK_FILE" -v "$VARIABLES_JSON"
    )
    [[ -n "$START_FROM" ]] && RUN_TASKS_ARGS+=(--start-from "$START_FROM")
    [[ "$CLEAN_STATE" == "true" ]] && RUN_TASKS_ARGS+=(--clean-state)
    bash "$SCRIPT_DIR/run-tasks.sh" "${RUN_TASKS_ARGS[@]}"
else
    pipeline_dispatch "$INSTANCE_ID" "$REGION" "$TASK_FILE" "$NEW_YML" "$VARIABLES_JSON" "$PIPELINE_NAME"
fi

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
