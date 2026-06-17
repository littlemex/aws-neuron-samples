#!/usr/bin/env bash
# reproduce.sh - one-shot wrapper for Pi0.5 LoRA fine-tune on Trainium2.
#
# What it does:
#   1. Calls setup/single-node/scripts/deploy.sh to bring up a trn2.3xlarge
#      (Capacity Block, Spot, or on-demand).
#   2. Ships bootstrap.sh + patches/*.patch to the instance via SSM and runs
#      bootstrap.sh as the coder user. bootstrap.sh clones openpi at the
#      pinned commit, applies the patches, sets up a venv, syncs the ckpt,
#      and runs one training step.
#   3. With --watch, polls the SSM command and prints the final log tail.
#
# Direct SSH is never used; everything runs through ssm send-command.
# AWS_PROFILE must be set in the caller's environment.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
DEPLOY_SH="${REPO_ROOT}/setup/single-node/scripts/deploy.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# ---- defaults ---------------------------------------------------------

REGION="${REGION:-${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-southeast-4}}}"
STACK_NAME="${STACK_NAME:-neuron-openpi-pi05-lora}"
EFS_SUBPATH="${EFS_SUBPATH:-/openpi-jax/main}"
INSTANCE_TYPE="${INSTANCE_TYPE:-trn2.3xlarge}"
SUBNET_ID="${SUBNET_ID:-}"
PURCHASE_MODE=""           # "" | "spot" | "cb"
CB_SLOT=""
CB_RESERVATION_ID=""
SPOT_BEHAVIOR="stop"
NUM_TRAIN_STEPS="${NUM_TRAIN_STEPS:-1}"
BATCH_SIZE="${BATCH_SIZE:-4}"
PI05_CONFIG="${PI05_CONFIG:-pi05_aloha_pen_uncap_lora}"
EXP_NAME="${EXP_NAME:-pi05_lora_trn2_$(date +%Y%m%d-%H%M%S)}"
WATCH=0
SKIP_DEPLOY=0
DRY_RUN=0
INSTANCE_ID="${INSTANCE_ID:-}"

usage() {
    cat <<EOF
reproduce.sh - one-shot reproduction of Pi0.5 LoRA fine-tune on Trainium2.

Usage: $0 [OPTIONS]

Options:
    -r, --region REGION        AWS region (default: \$AWS_REGION or ap-southeast-4)
    --stack-name NAME          CFN stack name (default: neuron-openpi-pi05-lora)
    --instance-type TYPE       EC2 instance type (default: trn2.3xlarge)
    --subnet-id ID             Subnet to launch in (must be in a trn2-capable AZ)
    --use-spot                 Launch as Spot
    --use-capacity-block       Launch against a Capacity Block reservation
                               (combine with --slot or --reservation-id)
    --slot NAME                SSM Parameter Store slot name (Capacity Block)
    --reservation-id ID        Capacity Reservation id (overrides --slot)
    --efs-subpath PATH         Subpath inside the EFS (default: /openpi-jax/main)
    --num-train-steps N        train.py --num-train-steps (default: 1)
    --batch-size N             train.py --batch-size (default: 4)
    --config NAME              TrainConfig name in config.py
                               (default: pi05_aloha_pen_uncap_lora)
    --exp-name NAME            train.py --exp-name (default: pi05_lora_trn2_<TS>)
    --skip-deploy              Skip deploy.sh; only run the bootstrap on the
                               existing stack
    --instance-id ID           Override the SSM target instance (use with
                               --skip-deploy)
    --watch                    Poll the SSM bootstrap command until it finishes
    --dry-run                  Print deploy / SSM commands without executing
    -h, --help                 Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -r|--region) REGION="$2"; shift 2 ;;
        --stack-name) STACK_NAME="$2"; shift 2 ;;
        --instance-type) INSTANCE_TYPE="$2"; shift 2 ;;
        --subnet-id) SUBNET_ID="$2"; shift 2 ;;
        --use-spot) PURCHASE_MODE="spot"; shift ;;
        --use-capacity-block) PURCHASE_MODE="cb"; shift ;;
        --slot) PURCHASE_MODE="cb"; CB_SLOT="$2"; shift 2 ;;
        --reservation-id) PURCHASE_MODE="cb"; CB_RESERVATION_ID="$2"; shift 2 ;;
        --efs-subpath) EFS_SUBPATH="$2"; shift 2 ;;
        --num-train-steps) NUM_TRAIN_STEPS="$2"; shift 2 ;;
        --batch-size) BATCH_SIZE="$2"; shift 2 ;;
        --config) PI05_CONFIG="$2"; shift 2 ;;
        --exp-name) EXP_NAME="$2"; shift 2 ;;
        --skip-deploy) SKIP_DEPLOY=1; shift ;;
        --instance-id) INSTANCE_ID="$2"; shift 2 ;;
        --watch) WATCH=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

if [[ -z "${AWS_PROFILE:-}" ]]; then
    echo -e "${YELLOW}AWS_PROFILE is not set. Export e.g. claude-code before rerunning.${NC}"
    exit 2
fi

if [[ ! -x "${DEPLOY_SH}" ]]; then
    echo -e "${RED}deploy.sh not found: ${DEPLOY_SH}${NC}"
    exit 2
fi

# Reject characters that would break the SSM JSON we generate later.
# (--exp-name / --config flow into a JSON-quoted command string.)
SAFE_TOKEN_RE='^[A-Za-z0-9._-]+$'
for VAR_NAME in EXP_NAME PI05_CONFIG; do
    eval "VAR_VALUE=\"\${${VAR_NAME}}\""
    if [[ ! "${VAR_VALUE}" =~ ${SAFE_TOKEN_RE} ]]; then
        echo -e "${RED}${VAR_NAME}='${VAR_VALUE}' contains characters outside [A-Za-z0-9._-]; refusing to embed in JSON.${NC}"
        exit 2
    fi
done

run() {
    echo -e "${BLUE}+ $*${NC}"
    if [[ "${DRY_RUN}" -eq 0 ]]; then
        "$@"
    fi
}

# ---- phase 1: deploy --------------------------------------------------

if [[ "${SKIP_DEPLOY}" -eq 0 ]]; then
    DEPLOY_ARGS=(
        -r "${REGION}"
        --stack-name "${STACK_NAME}"
        --instance-type "${INSTANCE_TYPE}"
        --create-efs
        --efs-subpath "${EFS_SUBPATH}"
        --install-claude-code
        --enable-explorer
    )
    if [[ -n "${SUBNET_ID}" ]]; then
        DEPLOY_ARGS+=(--subnet-id "${SUBNET_ID}")
    fi
    case "${PURCHASE_MODE}" in
        spot)
            DEPLOY_ARGS+=(--use-spot --spot-interruption-behavior "${SPOT_BEHAVIOR}")
            ;;
        cb)
            DEPLOY_ARGS+=(--use-capacity-block)
            if [[ -n "${CB_SLOT}" ]]; then
                DEPLOY_ARGS+=(--slot "${CB_SLOT}")
            fi
            if [[ -n "${CB_RESERVATION_ID}" ]]; then
                DEPLOY_ARGS+=(--capacity-reservation-id "${CB_RESERVATION_ID}")
            fi
            ;;
        "")
            : # on-demand
            ;;
    esac

    echo -e "${GREEN}[1/3] launching ${INSTANCE_TYPE} (${PURCHASE_MODE:-on-demand}) via deploy.sh${NC}"
    run bash "${DEPLOY_SH}" "${DEPLOY_ARGS[@]}"
fi

# ---- phase 2: locate instance -----------------------------------------

if [[ -z "${INSTANCE_ID}" ]]; then
    echo -e "${GREEN}[2/3] resolving InstanceId from CFN stack outputs${NC}"
    INSTANCE_ID="$(aws --region "${REGION}" cloudformation describe-stacks \
        --stack-name "${STACK_NAME}" \
        --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
        --output text 2>/dev/null || true)"
fi

if [[ -z "${INSTANCE_ID}" || "${INSTANCE_ID}" == "None" ]]; then
    echo -e "${RED}could not resolve InstanceId; pass --instance-id explicitly${NC}"
    exit 2
fi
echo "  InstanceId: ${INSTANCE_ID}"

# ---- phase 3: bootstrap via SSM ---------------------------------------

BOOTSTRAP_LOCAL="${SCRIPT_DIR}/bootstrap.sh"
PATCHES_DIR="${SCRIPT_DIR}/patches"

if [[ ! -f "${BOOTSTRAP_LOCAL}" ]]; then
    echo -e "${RED}bootstrap.sh not found: ${BOOTSTRAP_LOCAL}${NC}"
    exit 2
fi
if [[ ! -d "${PATCHES_DIR}" ]]; then
    echo -e "${RED}patches/ directory not found: ${PATCHES_DIR}${NC}"
    exit 2
fi

# Tar the bootstrap+patches and inline-base64 it into the SSM payload so we
# don't need an S3 bucket. Use a temp dir so EXIT trap reliably cleans up
# every artifact (mktemp + suffix would leave the original mktemp file).
TMP_DIR="$(mktemp -d -t pi05-lora-XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT
TMP_TGZ="${TMP_DIR}/payload.tgz"
SSM_PARAM_FILE="${TMP_DIR}/ssm-params.json"

tar -czf "${TMP_TGZ}" -C "${SCRIPT_DIR}" patches bootstrap.sh
B64="$(base64 < "${TMP_TGZ}" | tr -d '\n')"
PAYLOAD_SIZE_KB="$(wc -c < "${TMP_TGZ}" | awk '{printf "%.1f", $1/1024}')"
echo -e "${GREEN}[3/3] sending bootstrap to SSM (payload ${PAYLOAD_SIZE_KB} KB)${NC}"

cat > "${SSM_PARAM_FILE}" <<EOF
{
  "commands": [
    "set -e",
    "WD=/work/openpi-pi05-lora-reproduce",
    "sudo mkdir -p \$WD && sudo chown coder:coder \$WD",
    "sudo -u coder bash -c \"echo '${B64}' | base64 -d > \$WD/payload.tgz && tar -xzf \$WD/payload.tgz -C \$WD\"",
    "sudo -u coder bash -c \"chmod +x \$WD/bootstrap.sh\"",
    "sudo -u coder env NUM_TRAIN_STEPS=${NUM_TRAIN_STEPS} BATCH_SIZE=${BATCH_SIZE} PI05_CONFIG=${PI05_CONFIG} EXP_NAME=${EXP_NAME} bash \$WD/bootstrap.sh"
  ],
  "executionTimeout": ["3600"]
}
EOF

if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "(dry-run) SSM payload prepared at: ${SSM_PARAM_FILE}"
    exit 0
fi

CMD_ID="$(aws --region "${REGION}" ssm send-command \
    --instance-ids "${INSTANCE_ID}" \
    --document-name AWS-RunShellScript \
    --comment "openpi-pi05-lora-trn2 reproduce ${EXP_NAME}" \
    --parameters file://"${SSM_PARAM_FILE}" \
    --output text --query 'Command.CommandId')"

echo "  CommandId: ${CMD_ID}"

if [[ "${WATCH}" -eq 0 ]]; then
    cat <<EOF

Bootstrap submitted. To check progress:

  AWS_PROFILE=${AWS_PROFILE} aws --region ${REGION} ssm get-command-invocation \\
    --command-id ${CMD_ID} --instance-id ${INSTANCE_ID} \\
    --query 'StandardOutputContent' --output text

Train log lands at:
  /work/openpi-pi05-lora-reproduce/runs/${EXP_NAME}.log

EOF
    exit 0
fi

echo -e "${BLUE}--- bootstrap progress (--watch) ---${NC}"
while true; do
    STATUS="$(aws --region "${REGION}" ssm get-command-invocation \
        --command-id "${CMD_ID}" --instance-id "${INSTANCE_ID}" \
        --query 'Status' --output text 2>/dev/null || echo "InProgress")"
    case "${STATUS}" in
        Success|Failed|Cancelled|TimedOut)
            break
            ;;
    esac
    sleep 30
    echo "  status=${STATUS}"
done

echo -e "${GREEN}bootstrap finished: ${STATUS}${NC}"
aws --region "${REGION}" ssm get-command-invocation \
    --command-id "${CMD_ID}" --instance-id "${INSTANCE_ID}" \
    --query 'StandardOutputContent' --output text | tail -40

if [[ "${STATUS}" != "Success" ]]; then
    echo -e "${RED}bootstrap did not succeed; printing stderr tail:${NC}"
    aws --region "${REGION}" ssm get-command-invocation \
        --command-id "${CMD_ID}" --instance-id "${INSTANCE_ID}" \
        --query 'StandardErrorContent' --output text | tail -40
    exit 1
fi
