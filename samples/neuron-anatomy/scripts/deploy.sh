#!/bin/bash
# neuron-anatomy: one-shot deploy + integration helper.
#
# Steps:
#   precheck          read base/alb stack outputs (instance id, ALB ARN, SG)
#   backend           tarball -> S3 -> SSM Run Command -> systemd unit
#   infra             cdk deploy NeuronAnatomyStack (ALB rule /neuron/*)
#   integrate         (opt-in) patch voice-image-edit frontend to mount
#                     <NeuronDrawer /> in /edit
#
# Usage:
#   AWS_PROFILE=claude-code bash deploy.sh \
#     --base-stack-name storeai-validation-use2 \
#     --region us-east-2
#
# Flags:
#   --base-stack-name NAME     base CDK stack (e.g. storeai-validation-use2)
#   --alb-stack-name  NAME     ALB stack name (default: <base>-alb)
#   --region          REGION   AWS region (default: us-east-2)
#   --skip            CSV      step names to skip
#   --only            CSV      run only the listed steps
#   --integrate-voice-image-edit  add NeuronDrawer to voice-image-edit/edit
#   --dry-run                  just print the steps; no SSM / CDK calls
#
# Requirements:
#   - AWS_PROFILE exported (claude-code by team convention)
#   - the base ALB stack already exists with OriginVerifySecret etc.

set -euo pipefail

# -- color helpers --
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${BLUE}[anatomy]${NC} $*" >&2; }
ok()     { echo -e "${GREEN}[OK]${NC}        $*" >&2; }
warn()   { echo -e "${YELLOW}[WARN]${NC}      $*" >&2; }
err()    { echo -e "${RED}[NG]${NC}        $*" >&2; }
section(){ echo -e "\n${CYAN}========== $* ==========${NC}" >&2; }

# Always emit a final-line marker so an operator (or wrapper that only
# inspects logs) can detect failure even if the exit code is masked by a
# pipe such as `tee`.
CURRENT_STEP="(startup)"
on_exit() {
    local rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "" >&2
        echo -e "${RED}[anatomy][NG] failed at step '$CURRENT_STEP' (exit=$rc)${NC}" >&2
    fi
    exit $rc
}
trap on_exit EXIT

# -- defaults --
BASE_STACK_NAME=""
ALB_STACK_NAME=""
REGION="us-east-2"
SKIP_STEPS=""
ONLY_STEPS=""
INTEGRATE_VIE=false
DRY_RUN=false

ALL_STEPS=(precheck backend infra integrate)

while [[ $# -gt 0 ]]; do
    case "$1" in
        --base-stack-name) BASE_STACK_NAME="$2"; shift 2 ;;
        --alb-stack-name)  ALB_STACK_NAME="$2"; shift 2 ;;
        --region)          REGION="$2"; shift 2 ;;
        --skip)            SKIP_STEPS="$2"; shift 2 ;;
        --only)            ONLY_STEPS="$2"; shift 2 ;;
        --integrate-voice-image-edit) INTEGRATE_VIE=true; shift ;;
        --dry-run)         DRY_RUN=true; shift ;;
        -h|--help)
            sed -n '1,30p' "$0"
            exit 0
            ;;
        *)
            err "unknown flag: $1"
            exit 1
            ;;
    esac
done

if [[ -z "${AWS_PROFILE:-}" ]]; then
    err "AWS_PROFILE is required (must be 'claude-code' by team convention)"
    exit 1
fi
if [[ -z "$BASE_STACK_NAME" ]]; then
    err "--base-stack-name is required"
    exit 1
fi
ALB_STACK_NAME="${ALB_STACK_NAME:-${BASE_STACK_NAME}-alb}"

# Reject typos in --only/--skip up front.
validate_step_list() {
    local kind="$1" list="$2"
    [[ -z "$list" ]] && return 0
    local IFS=','
    for n in $list; do
        [[ -z "$n" ]] && continue
        local found=false
        for known in "${ALL_STEPS[@]}"; do
            [[ "$known" == "$n" ]] && { found=true; break; }
        done
        if [[ "$found" != true ]]; then
            err "unknown step in $kind: '$n'"
            err "  valid steps: ${ALL_STEPS[*]}"
            exit 1
        fi
    done
}
validate_step_list "--only" "$ONLY_STEPS"
validate_step_list "--skip" "$SKIP_STEPS"

should_skip() {
    local n="$1"
    if [[ -n "$ONLY_STEPS" ]]; then
        [[ ",$ONLY_STEPS," == *",$n,"* ]] && return 1 || return 0
    fi
    [[ ",$SKIP_STEPS," == *",$n,"* ]]
}

# -- locate paths --
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SAMPLE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../" && pwd)"
RUNNER="$REPO_ROOT/setup/single-node/scripts/run-tasks.sh"
ANATOMY_TASKS="$SAMPLE_DIR/scripts/tasks"
INFRA_DIR="$SAMPLE_DIR/infra"
BACKEND_DIR="$SAMPLE_DIR/backend"

[[ -x "$RUNNER" ]] || { err "$RUNNER missing or not executable"; exit 1; }

log "REPO_ROOT=$REPO_ROOT"
log "BASE_STACK_NAME=$BASE_STACK_NAME"
log "ALB_STACK_NAME=$ALB_STACK_NAME"
log "REGION=$REGION"
log "AWS_PROFILE=$AWS_PROFILE"
log "INTEGRATE_VIE=$INTEGRATE_VIE"
log "SKIP=${SKIP_STEPS:-(none)}"
log "ONLY=${ONLY_STEPS:-(none)}"
log "DRY_RUN=$DRY_RUN"

# ---------------------------------------------------------------------------
# step: precheck
#
# Resolve every value the rest of the deploy needs from CFN outputs:
#   - EC2_INSTANCE_ID, EC2_INSTANCE_SG, EC2_PRIVATE_IP, VPC_ID  (base)
#   - ALB_ARN, ALB_LISTENER_ARN, ALB_LISTENER_SG, ALB_SG, ORIGIN_VERIFY_SECRET_ARN  (alb)
#
# Always runs (even with --only) because every other step references these.
# ---------------------------------------------------------------------------
step_precheck() {
    section "precheck"
    log "describe-stack: $BASE_STACK_NAME"

    local outputs
    outputs=$(aws cloudformation describe-stacks \
        --stack-name "$BASE_STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs' --output json) || {
        err "base stack '$BASE_STACK_NAME' not found in $REGION"
        return 1
    }
    EC2_INSTANCE_ID=$(jq -r '.[]|select(.OutputKey=="InstanceId" or .OutputKey=="Ec2InstanceId").OutputValue // empty' <<<"$outputs" | head -1)
    EC2_INSTANCE_SG=$(jq -r '.[]|select(.OutputKey=="SecurityGroupId").OutputValue // empty' <<<"$outputs" | head -1)
    [[ -z "$EC2_INSTANCE_ID" ]] && { err "InstanceId output missing on $BASE_STACK_NAME"; return 1; }

    EC2_PRIVATE_IP=$(aws ec2 describe-instances --instance-ids "$EC2_INSTANCE_ID" --region "$REGION" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text 2>/dev/null)
    VPC_ID=$(aws ec2 describe-instances --instance-ids "$EC2_INSTANCE_ID" --region "$REGION" \
        --query 'Reservations[0].Instances[0].VpcId' --output text 2>/dev/null)

    log "describe-stack: $ALB_STACK_NAME"
    local alb_outputs
    alb_outputs=$(aws cloudformation describe-stacks \
        --stack-name "$ALB_STACK_NAME" --region "$REGION" \
        --query 'Stacks[0].Outputs' --output json 2>/dev/null) || {
        err "ALB stack '$ALB_STACK_NAME' not found in $REGION (use --alb-stack-name)"
        return 1
    }

    # Output keys vary across deploys; try the common ones.
    ALB_ARN=$(jq -r '.[]|select(.OutputKey | test("^Alb(Arn|LoadBalancerArn)$")).OutputValue // empty' <<<"$alb_outputs" | head -1)
    ALB_LISTENER_ARN=$(jq -r '.[]|select(.OutputKey | test("(Listener|HttpListener)Arn$")).OutputValue // empty' <<<"$alb_outputs" | head -1)
    ALB_SG=$(jq -r '.[]|select(.OutputKey | test("AlbSecurityGroupId$|AlbSgId$")).OutputValue // empty' <<<"$alb_outputs" | head -1)
    ALB_LISTENER_SG="$ALB_SG"  # the ALB's own SG carries the listener
    ORIGIN_VERIFY_SECRET_ARN=$(jq -r '.[]|select(.OutputKey | test("OriginVerifySecretArn$")).OutputValue // empty' <<<"$alb_outputs" | head -1)

    # Fall back: scan the stack resources for an ALB / listener if outputs differ.
    if [[ -z "$ALB_ARN" ]]; then
        ALB_ARN=$(aws cloudformation describe-stack-resources --stack-name "$ALB_STACK_NAME" --region "$REGION" \
            --query "StackResources[?ResourceType=='AWS::ElasticLoadBalancingV2::LoadBalancer'].PhysicalResourceId|[0]" --output text 2>/dev/null)
    fi
    if [[ -z "$ALB_LISTENER_ARN" ]]; then
        ALB_LISTENER_ARN=$(aws cloudformation describe-stack-resources --stack-name "$ALB_STACK_NAME" --region "$REGION" \
            --query "StackResources[?ResourceType=='AWS::ElasticLoadBalancingV2::Listener'].PhysicalResourceId|[0]" --output text 2>/dev/null)
    fi
    if [[ -z "$ALB_SG" ]]; then
        ALB_SG=$(aws cloudformation describe-stack-resources --stack-name "$ALB_STACK_NAME" --region "$REGION" \
            --query "StackResources[?ResourceType=='AWS::EC2::SecurityGroup'].PhysicalResourceId|[0]" --output text 2>/dev/null)
        ALB_LISTENER_SG="$ALB_SG"
    fi

    for var in EC2_INSTANCE_ID EC2_INSTANCE_SG EC2_PRIVATE_IP VPC_ID ALB_ARN ALB_LISTENER_ARN ALB_LISTENER_SG ALB_SG ORIGIN_VERIFY_SECRET_ARN; do
        if [[ -z "${!var:-}" || "${!var}" == "None" ]]; then
            err "could not resolve $var from CFN outputs/resources"
            return 1
        fi
    done

    ok "EC2_INSTANCE_ID=$EC2_INSTANCE_ID  PRIVATE_IP=$EC2_PRIVATE_IP  VPC=$VPC_ID"
    ok "ALB_ARN=$ALB_ARN"
    ok "ALB_LISTENER_ARN=$ALB_LISTENER_ARN"

    export EC2_INSTANCE_ID EC2_INSTANCE_SG EC2_PRIVATE_IP VPC_ID
    export ALB_ARN ALB_LISTENER_ARN ALB_LISTENER_SG ALB_SG ORIGIN_VERIFY_SECRET_ARN
}

# ---------------------------------------------------------------------------
# helpers: S3 staging bucket and tarball upload (mirrors voice-image-edit/scripts/deploy-all.sh)
# ---------------------------------------------------------------------------
ensure_stage_bucket() {
    local account_id
    account_id=$(aws sts get-caller-identity --query Account --output text)
    local short="${REGION//-/}"
    STAGE_BUCKET="${STAGE_BUCKET_OVERRIDE:-neuron-anatomy-stage-${short}-${account_id:0:6}}"
    if ! aws s3api head-bucket --bucket "$STAGE_BUCKET" --region "$REGION" >/dev/null 2>&1; then
        log "creating S3 bucket s3://$STAGE_BUCKET"
        if [[ "$REGION" == "us-east-1" ]]; then
            aws s3api create-bucket --bucket "$STAGE_BUCKET" --region "$REGION" >/dev/null
        else
            aws s3api create-bucket --bucket "$STAGE_BUCKET" --region "$REGION" \
                --create-bucket-configuration LocationConstraint="$REGION" >/dev/null
        fi
    fi
    log "STAGE_BUCKET=$STAGE_BUCKET"
}

stage_dir_to_s3() {
    local dir="$1" key="$2"
    ensure_stage_bucket
    local tmp
    tmp=$(mktemp "/tmp/${key}.XXXXXX")
    ( cd "$dir" && tar --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --exclude='tests' \
        --exclude='*.egg-info' --exclude='build' --exclude='dist' \
        -czf "$tmp" . )
    aws s3 cp "$tmp" "s3://$STAGE_BUCKET/staging/$key" --no-progress >/dev/null
    rm -f "$tmp"
    aws s3 presign "s3://$STAGE_BUCKET/staging/$key" --expires-in 86400 --region "$REGION"
}

run_task_json() {
    local task_file="$1" vars_json="${2:-{\}}" state_label="${3:-$(basename "$task_file" .json)}"
    local state_file="/tmp/task-state-${EC2_INSTANCE_ID}-${state_label}.json"
    if [[ "$DRY_RUN" == true ]]; then
        log "[dry] $RUNNER -i $EC2_INSTANCE_ID -r $REGION -f $task_file -v '$vars_json' --state-file $state_file"
        return 0
    fi
    log "running: $task_file (state=$state_file)"
    "$RUNNER" -i "$EC2_INSTANCE_ID" -r "$REGION" -f "$task_file" -v "$vars_json" --state-file "$state_file"
}

# ---------------------------------------------------------------------------
# step: backend (deploy systemd unit)
# ---------------------------------------------------------------------------
step_backend() {
    section "backend"
    local tarball_url
    tarball_url=$(stage_dir_to_s3 "$BACKEND_DIR" neuron-anatomy-backend.tar.gz) || return 1
    local vars
    vars=$(jq -nc --arg url "$tarball_url" '{SOURCE_TARBALL_URL:$url}')
    TASK_MAX_WAIT_SECONDS=900 \
        run_task_json "$ANATOMY_TASKS/neuron-anatomy-server.json" "$vars" neuron-anatomy-server
    ok "neuron-anatomy.service installed on $EC2_INSTANCE_ID"
}

# ---------------------------------------------------------------------------
# step: infra (cdk deploy NeuronAnatomyStack)
# ---------------------------------------------------------------------------
ensure_infra_node_modules() {
    if [[ ! -d "$INFRA_DIR/node_modules" ]]; then
        log "installing CDK node_modules in $INFRA_DIR"
        ( cd "$INFRA_DIR" && npm install --silent ) || {
            err "npm install failed"
            return 1
        }
    fi
}

step_infra() {
    section "infra"
    ensure_infra_node_modules

    local stack_name="${BASE_STACK_NAME}-neuron-anatomy"
    local cdk_args=(
        deploy "$stack_name"
        -c "stackName=$stack_name"
        -c "albArn=$ALB_ARN"
        -c "albListenerArn=$ALB_LISTENER_ARN"
        -c "albListenerSgId=$ALB_LISTENER_SG"
        -c "albSecurityGroupId=$ALB_SG"
        -c "originVerifyHeaderName=X-Origin-Verify"
        -c "originVerifySecretArn=$ORIGIN_VERIFY_SECRET_ARN"
        -c "anatomyInstancePrivateIp=$EC2_PRIVATE_IP"
        -c "anatomyInstanceSgId=$EC2_INSTANCE_SG"
        -c "anatomyVpcId=$VPC_ID"
        --require-approval never
    )

    if [[ "$DRY_RUN" == true ]]; then
        log "[dry] cd $INFRA_DIR && npx cdk ${cdk_args[*]}"
        return 0
    fi

    ( cd "$INFRA_DIR" && AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
        npx cdk "${cdk_args[@]}" )
    ok "NeuronAnatomyStack deployed (rule /neuron/* priority 250)"
}

# ---------------------------------------------------------------------------
# step: integrate (opt-in; patch voice-image-edit frontend to mount the drawer)
# ---------------------------------------------------------------------------
step_integrate() {
    section "integrate"
    if [[ "$INTEGRATE_VIE" != true ]]; then
        warn "integrate step skipped (pass --integrate-voice-image-edit to enable)"
        return 0
    fi

    local vie_frontend="$REPO_ROOT/samples/voice-image-edit/app/frontend"
    local edit_page="$vie_frontend/src/app/edit/page.tsx"
    local pkg="$vie_frontend/package.json"

    [[ -f "$edit_page" ]] || { err "voice-image-edit edit page not found at $edit_page"; return 1; }
    [[ -f "$pkg" ]] || { err "voice-image-edit package.json not found at $pkg"; return 1; }

    # 1) add the file: dependency if missing.
    if ! grep -q '"@aws-neuron-samples/neuron-anatomy"' "$pkg"; then
        log "adding @aws-neuron-samples/neuron-anatomy to $pkg"
        if [[ "$DRY_RUN" == true ]]; then
            log "[dry] would inject \"@aws-neuron-samples/neuron-anatomy\": \"file:../../../neuron-anatomy/frontend\""
        else
            python3 - "$pkg" <<'PY'
import json, sys, pathlib
p = pathlib.Path(sys.argv[1])
data = json.loads(p.read_text())
deps = data.setdefault('dependencies', {})
deps['@aws-neuron-samples/neuron-anatomy'] = 'file:../../../neuron-anatomy/frontend'
p.write_text(json.dumps(data, indent=2) + '\n')
print(f"[OK] {p}: added @aws-neuron-samples/neuron-anatomy")
PY
        fi
    else
        ok "package.json already references @aws-neuron-samples/neuron-anatomy"
    fi

    # 2) inject the import + drawer into edit/page.tsx if missing.
    if ! grep -q 'NeuronDrawer' "$edit_page"; then
        log "injecting NeuronDrawer into $edit_page"
        if [[ "$DRY_RUN" == true ]]; then
            log "[dry] would inject NeuronDrawer import + <NeuronDrawer base=\"/neuron\" defaultOpen /> at end of <main>"
        else
            python3 - "$edit_page" <<'PY'
import re, sys, pathlib
p = pathlib.Path(sys.argv[1])
src = p.read_text()
if 'NeuronDrawer' in src:
    print('[OK] already integrated'); raise SystemExit(0)
# Insert the import after the last existing import line.
imports = list(re.finditer(r"^import .+;$", src, re.M))
if not imports:
    print('[NG] no import line found in edit/page.tsx', file=sys.stderr); raise SystemExit(1)
last = imports[-1]
new_import = "\nimport { NeuronDrawer } from '@aws-neuron-samples/neuron-anatomy';"
src = src[:last.end()] + new_import + src[last.end():]
# Insert <NeuronDrawer ... /> right before the closing </main>.
m = re.search(r"</main>", src)
if not m:
    print('[NG] no </main> found in edit/page.tsx', file=sys.stderr); raise SystemExit(1)
drawer = '\n      <NeuronDrawer base="/neuron" defaultOpen />\n    '
src = src[:m.start()] + drawer + src[m.start():]
p.write_text(src)
print(f"[OK] {p}: NeuronDrawer mounted at end of <main>")
PY
        fi
    else
        ok "edit/page.tsx already mounts NeuronDrawer"
    fi

    warn "voice-image-edit frontend was patched in place. Re-run voice-image-edit/scripts/deploy-all.sh --only voice-image-edit-app to ship it to EC2."
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------
CURRENT_STEP="precheck"
step_precheck

START_TS=$(date +%s)
for step in "${ALL_STEPS[@]}"; do
    [[ "$step" == "precheck" ]] && continue
    if should_skip "$step"; then
        warn "skip: $step"
        continue
    fi
    CURRENT_STEP="$step"
    case "$step" in
        backend)   step_backend ;;
        infra)     step_infra ;;
        integrate) step_integrate ;;
        *)         err "unknown step: $step"; exit 1 ;;
    esac
done

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
ok "neuron-anatomy deploy finished in ${ELAPSED}s"
echo ""
echo "Smoke tests (CloudFront + Cognito cookie required):"
echo "  curl -sS https://<cloudfront-domain>/neuron/health    --cookie 'cf_session=...'"
echo "  curl -sS https://<cloudfront-domain>/neuron/topology  --cookie 'cf_session=...' | head -c 400"
echo "  curl -sN https://<cloudfront-domain>/neuron/stream    --cookie 'cf_session=...' | head -50"
