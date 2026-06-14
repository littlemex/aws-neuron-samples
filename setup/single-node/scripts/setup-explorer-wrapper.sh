#!/bin/bash
# setup-explorer-wrapper.sh
#
# Thin wrapper around run-tasks.sh that:
#
#   1. Encodes scripts/setup-explorer.sh as base64 and drops it on the
#      target instance at /tmp/setup-explorer.sh via SSM Run Command.
#   2. Invokes run-tasks.sh with tasks/explorer-setup.json so the
#      systemd unit + nginx fragment land idempotently.
#
# Used by deploy.sh when --enable-explorer is set, and standalone for
# re-runs after a Spot stop/start (no other tasks need to re-execute).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
    cat <<EOF
setup-explorer-wrapper.sh - install Neuron Explorer behind nginx /explorer/

Usage: $0 [OPTIONS]

Options:
    -i, --instance-id ID                Target EC2 instance ID (required)
    -r, --region REGION                 AWS region (default: sa-east-1)
        --explorer-user USER            User that owns the systemd unit
                                        (default: coder)
        --explorer-port PORT            UI port (default: 8181 — 8081 is
                                        used by qwen-image-edit on
                                        voice-image-edit deploys, so the
                                        default was bumped to 8181 to keep
                                        --enable-explorer collision-free)
        --explorer-api-port PORT        API port the binary opens on
                                        (default: 3002, not configurable
                                        on neuron-explorer 2.29; keep in
                                        sync with the upstream tool)
        --explorer-data-dir DIR         State dir owned by the unit
                                        (default: /var/lib/neuron-explorer)
        --explorer-display-name NAME    Human-friendly display name
                                        (default: workshop)
        --nginx-location PATH           Sub-path served from nginx
                                        (default: /explorer)
        --start-from TASK_ID            Resume from the specified task ID
        --clean-state                   Clear state file and run from start
        --dry-run                       Print plan only, do not execute
        --use-pipeline-runner           Dispatch through tools/pipeline-runner
                                        instead of the legacy run-tasks.sh.
    -h, --help                          Show this help

Examples:
    $0 -i i-1234567890abcdef0
    $0 -i i-1234567890abcdef0 --explorer-display-name nki-bootcamp
EOF
}

INSTANCE_ID=""
REGION="sa-east-1"
EXPLORER_USER="coder"
EXPLORER_PORT="8181"
EXPLORER_API_PORT="3002"
EXPLORER_DATA_DIR="/var/lib/neuron-explorer"
EXPLORER_DISPLAY_NAME="workshop"
NGINX_LOCATION="/explorer"
START_FROM=""
CLEAN_STATE=false
DRY_RUN=false
USE_PIPELINE_RUNNER="${USE_PIPELINE_RUNNER:-false}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--instance-id) INSTANCE_ID="$2"; shift 2 ;;
        -r|--region) REGION="$2"; shift 2 ;;
        --explorer-user) EXPLORER_USER="$2"; shift 2 ;;
        --explorer-port) EXPLORER_PORT="$2"; shift 2 ;;
        --explorer-api-port) EXPLORER_API_PORT="$2"; shift 2 ;;
        --explorer-data-dir) EXPLORER_DATA_DIR="$2"; shift 2 ;;
        --explorer-display-name) EXPLORER_DISPLAY_NAME="$2"; shift 2 ;;
        --nginx-location) NGINX_LOCATION="$2"; shift 2 ;;
        --start-from) START_FROM="$2"; shift 2 ;;
        --clean-state) CLEAN_STATE=true; shift ;;
        --dry-run) DRY_RUN=true; shift ;;
        --use-pipeline-runner) USE_PIPELINE_RUNNER=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

[[ -z "$INSTANCE_ID" ]] && { echo "ERROR: --instance-id is required"; exit 2; }

EXPLORER_SH="$SCRIPT_DIR/setup-explorer.sh"
REWRITER_SH="$SCRIPT_DIR/rewrite-explorer-bundle.py"
CAPTURE_SH="$SCRIPT_DIR/capture-and-upload.sh"
TASK_FILE="$PROJECT_DIR/tasks/explorer-setup.json"

[[ -f "$EXPLORER_SH" ]] || { echo "ERROR: $EXPLORER_SH missing"; exit 2; }
[[ -f "$REWRITER_SH" ]] || { echo "ERROR: $REWRITER_SH missing"; exit 2; }
[[ -f "$CAPTURE_SH" ]]  || { echo "ERROR: $CAPTURE_SH missing"; exit 2; }
[[ -f "$TASK_FILE" ]]   || { echo "ERROR: $TASK_FILE missing"; exit 2; }

# Helper: upload a small file as base64 over SSM Run Command, then
# verify the upload completed.  Returns 0 on success, exits the
# script on hard failure.
_ssm_upload() {
    local local_path="$1" remote_path="$2"
    local b64
    b64=$(base64 < "$local_path" | tr -d '\n')
    local cid
    cid=$(aws ssm send-command --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --document-name AWS-RunShellScript \
        --parameters "commands=[\"bash -c \\\"echo '${b64}' | base64 -d > ${remote_path} && wc -c ${remote_path}\\\"\"]" \
        --query 'Command.CommandId' --output text 2>/dev/null)

    local s
    for _ in 1 2 3 4 5 6 7 8; do
        sleep 4
        s=$(aws ssm get-command-invocation --region "$REGION" \
            --command-id "$cid" --instance-id "$INSTANCE_ID" \
            --query 'Status' --output text 2>/dev/null || echo "Pending")
        [[ "$s" == "Success" || "$s" == "Failed" ]] && break
    done
    if [[ "$s" != "Success" ]]; then
        echo "ERROR: failed to upload $local_path (status=$s)"
        aws ssm get-command-invocation --region "$REGION" \
            --command-id "$cid" --instance-id "$INSTANCE_ID" \
            --query 'StandardErrorContent' --output text 2>/dev/null | head -20
        exit 1
    fi
}

# 1. Upload setup-explorer.sh (idempotent host-side installer).
echo "==> Uploading setup-explorer.sh to instance (/tmp/setup-explorer.sh)"
_ssm_upload "$EXPLORER_SH" "/tmp/setup-explorer.sh"
aws ssm send-command --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["chmod +x /tmp/setup-explorer.sh"]' \
    --output text >/dev/null
echo "    [OK] setup-explorer.sh uploaded"

# 2. Upload rewrite-explorer-bundle.py next to it; setup-explorer.sh
#    expects to find it at the same directory as itself.  We park it
#    in /tmp so a non-root SSM session can write it, then setup-
#    explorer.sh installs it under /opt/neuron-explorer/ as root.
echo "==> Uploading rewrite-explorer-bundle.py to instance (/tmp/rewrite-explorer-bundle.py)"
_ssm_upload "$REWRITER_SH" "/tmp/rewrite-explorer-bundle.py"
aws ssm send-command --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["chmod +x /tmp/rewrite-explorer-bundle.py"]' \
    --output text >/dev/null
echo "    [OK] rewrite-explorer-bundle.py uploaded"

# 3. Upload capture-and-upload.sh helper.  setup-explorer.sh installs
#    it under /opt/neuron-explorer/ alongside the rewriter so users
#    can invoke a single command to capture + push a profile.
echo "==> Uploading capture-and-upload.sh to instance (/tmp/capture-and-upload.sh)"
_ssm_upload "$CAPTURE_SH" "/tmp/capture-and-upload.sh"
aws ssm send-command --region "$REGION" \
    --instance-ids "$INSTANCE_ID" \
    --document-name AWS-RunShellScript \
    --parameters 'commands=["chmod +x /tmp/capture-and-upload.sh"]' \
    --output text >/dev/null
echo "    [OK] capture-and-upload.sh uploaded"

# Build variables.json for run-tasks.sh
VARIABLES_JSON=$(python3 -c "
import json
print(json.dumps({
    'EXPLORER_USER': '${EXPLORER_USER}',
    'EXPLORER_PORT': '${EXPLORER_PORT}',
    'EXPLORER_API_PORT': '${EXPLORER_API_PORT}',
    'EXPLORER_DATA_DIR': '${EXPLORER_DATA_DIR}',
    'EXPLORER_DISPLAY_NAME': '${EXPLORER_DISPLAY_NAME}',
    'NGINX_LOCATION': '${NGINX_LOCATION}',
}))
")

REPO_ROOT="$(cd "$PROJECT_DIR/../.." && pwd)"
DISPATCH_HELPER="$REPO_ROOT/tools/pipeline-runner/lib-sh/dispatch.sh"
if [[ ! -f "$DISPATCH_HELPER" ]]; then
    echo "Error: dispatch helper missing at $DISPATCH_HELPER"
    exit 1
fi
export REPO_ROOT
# shellcheck disable=SC1090
source "$DISPATCH_HELPER"

PIPELINE_NAME="$(basename "$TASK_FILE" .json)"
NEW_YML="$PROJECT_DIR/pipelines/${PIPELINE_NAME}/${PIPELINE_NAME}.yml"

if [[ "$USE_PIPELINE_RUNNER" == "true" ]]; then
    if [[ -n "$START_FROM" || "$CLEAN_STATE" == "true" || "$DRY_RUN" == "true" ]]; then
        echo "[INFO] --start-from / --clean-state / --dry-run on the new runner: invoke run-pipeline directly with rerun --from / --force-all / --dry-run against $NEW_YML for fine control."
    fi
fi

if [[ "$DRY_RUN" == "true" && "$USE_PIPELINE_RUNNER" != "true" ]]; then
    bash "$SCRIPT_DIR/run-tasks.sh" -i "$INSTANCE_ID" -r "$REGION" -f "$TASK_FILE" -v "$VARIABLES_JSON" --dry-run
elif [[ "$USE_PIPELINE_RUNNER" != "true" && (-n "$START_FROM" || "$CLEAN_STATE" == "true") ]]; then
    RUN_TASKS_ARGS=( -i "$INSTANCE_ID" -r "$REGION" -f "$TASK_FILE" -v "$VARIABLES_JSON" )
    [[ -n "$START_FROM" ]] && RUN_TASKS_ARGS+=(--start-from "$START_FROM")
    [[ "$CLEAN_STATE" == "true" ]] && RUN_TASKS_ARGS+=(--clean-state)
    bash "$SCRIPT_DIR/run-tasks.sh" "${RUN_TASKS_ARGS[@]}"
else
    pipeline_dispatch "$INSTANCE_ID" "$REGION" "$TASK_FILE" "$NEW_YML" "$VARIABLES_JSON" "$PIPELINE_NAME"
fi
