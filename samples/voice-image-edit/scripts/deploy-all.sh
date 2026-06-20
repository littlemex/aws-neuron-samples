#!/bin/bash
# voice-image-edit one-shot deploy
#
# Each step is idempotent. After a CodeBuild Capacity Block or Spot termination,
# re-running the script reuses cached artifacts (Neuron compile, HF download,
# NEFF cache) to bring services back up without a full cold build.
#
#   precheck            verify base stack outputs / EFS mount / NeuronCore
#   setup-efs-paths     create EFS-backed symlinks for /models, /opt/voice-image-edit, compile artifacts
#   whisper-precompile  compile encoder/decoder/proj.pt to EFS (skips on cache hit)
#   qwen3-vl-prepare    download weights + run vLLM warmup to EFS (skips on cache hit)
#   qwen-image-edit-prepare  compile V3 CFG 5 components to EFS (skips on cache hit)
#   whisper-server      install + start systemd unit (port 8765)
#   qwen3-vl-server     install + start systemd unit (port 8090)
#   qwen-image-edit-server  install + start systemd unit (port 8081)
#   voice-image-edit-app  inject TRAINIUM_*_URL into ApiStack/FrontendStack/StreamStack
#   neuron-anatomy      sibling stack: re-wire ALB rule /neuron/* + backend on EC2
#
# Usage:
#   bash deploy-all.sh \
#     --base-stack-name storeai-validation-use2 \
#     --region us-east-2
#
# Key flags:
#   --base-stack-name   base stack name (EC2 instance and EFS mount info from CFn outputs)
#   --region            AWS region (default: us-east-2)
#   --skip <names>      comma-separated steps to skip (e.g. "setup-efs-paths,migrate-to-efs")
#   --only <names>      run only the listed steps (debug)
#   --migrate           include migrate-to-efs before setup-efs-paths (first-time EFS migration)
#   --recover           recovery mode after CB/Spot termination (= --skip migrate-to-efs, default)
#   --reset-app-stacks  forwarded to app/infra/deploy.sh: destroy VoiceImageEdit*
#                       stacks orphaned against a rebuilt base ALB before deploy
#   --dry-run           print each step without sending SSM commands
#   --use-pipeline-runner  accepted for backward compatibility; YAML pipeline runner is always used
#
# Required environment variable:
#   AWS_PROFILE=claude-code
set -euo pipefail

# Always emit a final-line marker so an operator (or wrapper that looks
# only at logs) can tell success from failure even if exit code is
# masked by `tee` or other pipe gymnastics. The trap fires on any
# non-zero exit including unbound-variable, set -e, or signals.
CURRENT_STEP="(startup)"
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 ]]; then
    echo "" >&2
    echo -e "\033[0;31m[deploy-all][NG] failed at step '$CURRENT_STEP' (exit=$rc)\033[0m" >&2
  fi
  exit $rc
}
trap on_exit EXIT

# --- color helpers ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

log()    { echo -e "${BLUE}[deploy-all]${NC} $*" >&2; }
ok()     { echo -e "${GREEN}[OK]${NC}        $*" >&2; }
warn()   { echo -e "${YELLOW}[WARN]${NC}      $*" >&2; }
err()    { echo -e "${RED}[NG]${NC}        $*" >&2; }
section(){ echo -e "\n${CYAN}========== $* ==========${NC}" >&2; }

# --- defaults ---
BASE_STACK_NAME=""
REGION="us-east-2"
SKIP_STEPS=""
ONLY_STEPS=""
MIGRATE=false
DRY_RUN=false
# Forwarded to app/infra/deploy.sh so a rebuilt base ALB does not leave the
# VoiceImageEdit{Api,Frontend,Stream} stacks orphaned against the old ALB.
RESET_APP_STACKS=false
# Accepted for backward compatibility; YAML pipeline runner is always used.
USE_PIPELINE_RUNNER="${USE_PIPELINE_RUNNER:-true}"

# Step granularity: --skip prepare で 3 prepare 全部 skip / --skip setup-efs-paths で 1 step skip
#
# neuron-anatomy is a sibling stack that pins an ALB target group to the
# voice-image-edit EC2 by private IP. Every recover gives the EC2 a new
# private IP, so the anatomy target group goes unhealthy unless we also
# re-run the anatomy deploy (CDK update + backend tarball redeploy). This
# step is intentionally last so the ALB / app stacks have already settled
# by the time anatomy updates the listener rule and target group.
ALL_STEPS=(
  precheck
  setup-efs-paths
  migrate-to-efs
  whisper-precompile
  qwen3-vl-prepare
  qwen-image-edit-prepare
  xttsv2-precompile
  whisper-server
  qwen3-vl-server
  qwen-image-edit-server
  xttsv2-server
  voice-image-edit-app
  neuron-anatomy
)

while [[ $# -gt 0 ]]; do
  case $1 in
    --base-stack-name) BASE_STACK_NAME="$2"; shift 2 ;;
    --region)          REGION="$2"; shift 2 ;;
    --skip)            SKIP_STEPS="$2"; shift 2 ;;
    --only)            ONLY_STEPS="$2"; shift 2 ;;
    --migrate)         MIGRATE=true; shift ;;
    --recover)         MIGRATE=false; shift ;;
    --reset-app-stacks) RESET_APP_STACKS=true; shift ;;
    --dry-run)         DRY_RUN=true; shift ;;
    --use-pipeline-runner) shift ;;  # no-op: YAML runner is always used
    -h|--help)
      sed -n '1,40p' "$0"
      exit 0
      ;;
    *)
      err "unknown flag: $1"
      exit 1
      ;;
  esac
done

if [[ -z "${AWS_PROFILE:-}" ]]; then
  err "AWS_PROFILE is required (must be 'claude-code')"
  exit 1
fi

if [[ -z "$BASE_STACK_NAME" ]]; then
  err "--base-stack-name is required"
  exit 1
fi

# --migrate でなければ migrate-to-efs を skip 扱い
if [[ "$MIGRATE" != true ]]; then
  if [[ -n "$SKIP_STEPS" ]]; then
    SKIP_STEPS="${SKIP_STEPS},migrate-to-efs"
  else
    SKIP_STEPS="migrate-to-efs"
  fi
fi

should_skip() {
  local name="$1"
  if [[ -n "$ONLY_STEPS" ]]; then
    [[ ",$ONLY_STEPS," == *",$name,"* ]] && return 1 || return 0
  fi
  [[ ",$SKIP_STEPS," == *",$name,"* ]]
}

# Validate --only / --skip values match real step names. Catches typos
# such as --only qwen3vl-server (missing the "-vl-") which would
# otherwise silently skip everything and exit 0.
validate_step_list() {
  local kind="$1"   # "--only" or "--skip"
  local list="$2"
  [[ -z "$list" ]] && return 0
  local IFS=','
  for name in $list; do
    [[ -z "$name" ]] && continue
    local found=false
    for known in "${ALL_STEPS[@]}"; do
      [[ "$known" == "$name" ]] && { found=true; break; }
    done
    if [[ "$found" != true ]]; then
      err "unknown step in $kind: '$name'"
      err "  valid steps: ${ALL_STEPS[*]}"
      exit 1
    fi
  done
}
validate_step_list "--only" "$ONLY_STEPS"
validate_step_list "--skip" "$SKIP_STEPS"

# --- locate paths ---
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VIE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../" && pwd)"  # samples/.. = repo root
WHISPER_TASKS="$REPO_ROOT/samples/models/whisper/tasks"
QWEN3VL_TASKS="$REPO_ROOT/samples/models/qwen3-vl/tasks"
QIE_TASKS="$REPO_ROOT/samples/models/qwen-image-edit/tasks"
XTTSV2_TASKS="$REPO_ROOT/samples/models/xttsv2/tasks"
XTTSV2_DIR="$REPO_ROOT/samples/models/xttsv2"
SCRIPTS_TASKS="$VIE_DIR/scripts/tasks"
APP_INFRA_DIR="$VIE_DIR/app/infra"

log "REPO_ROOT=$REPO_ROOT"
log "BASE_STACK_NAME=$BASE_STACK_NAME"
log "REGION=$REGION"
log "AWS_PROFILE=$AWS_PROFILE"
log "MIGRATE=$MIGRATE"
log "SKIP=${SKIP_STEPS:-(none)}"
log "ONLY=${ONLY_STEPS:-(none)}"
log "DRY_RUN=$DRY_RUN"

# --- step: precheck ---
step_precheck() {
  section "precheck"
  log "describe-stack: $BASE_STACK_NAME"
  local outputs
  outputs=$(aws cloudformation describe-stacks \
    --stack-name "$BASE_STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs' --output json) || {
      err "base stack '$BASE_STACK_NAME' not found in region $REGION"
      return 1
    }
  EC2_INSTANCE_ID=$(jq -r '.[]|select(.OutputKey=="InstanceId" or .OutputKey=="Ec2InstanceId").OutputValue // empty' <<< "$outputs" | head -1)
  EC2_PUBLIC_IP=$(jq -r '.[]|select(.OutputKey=="InstancePublicIp" or .OutputKey=="Ec2InstancePublicIp").OutputValue // empty' <<< "$outputs" | head -1)
  EFS_ID=$(jq -r '.[]|select(.OutputKey=="EfsId" or .OutputKey=="EfsFileSystemId").OutputValue // empty' <<< "$outputs" | head -1)
  if [[ -z "$EC2_INSTANCE_ID" ]]; then
    err "base stack output 'InstanceId' not found (also tried 'Ec2InstanceId')"
    return 1
  fi
  ok "EC2_INSTANCE_ID=$EC2_INSTANCE_ID  EFS_ID=${EFS_ID:-(unknown)}  PUBLIC_IP=${EC2_PUBLIC_IP:-(unknown)}"
  EC2_INSTANCE_TYPE=$(aws ec2 describe-instances \
    --instance-ids "$EC2_INSTANCE_ID" --region "$REGION" \
    --query 'Reservations[0].Instances[0].InstanceType' --output text 2>/dev/null || true)
  ok "EC2_INSTANCE_TYPE=${EC2_INSTANCE_TYPE:-(unknown)}"
  export EC2_INSTANCE_ID EC2_PUBLIC_IP EFS_ID EC2_INSTANCE_TYPE
}

# --- helper: pick xttsv2 profile per host (TP, NeuronCores, compile path) ---
# trn2.3xlarge has a single chip (cores 0-3). trn2.48xlarge has 16 chips (0-63);
# whisper occupies 8-15, qwen3-vl 16-31, qwen-image-edit 32-63
# (= 2 chips, 8 cores) free for xttsv2 — TP=8 is the largest power-of-two that
# fits and roughly halves prefill latency over TP=4. The compile artefact path
# is suffixed with the TP degree because the NEFFs are not interchangeable
# across degrees and /models is shared via EFS.
xttsv2_profile_for_instance() {
  local itype="$1"
  # Always TP=4 / cores 0-3 / NeuronDevice 0. The container's bundled
  # neuron-rt 2.30 crashes (tdrv bdf-workaround assertion) when given any
  # high-index NeuronDevice on trn2.48xlarge, so xttsv2 sticks to the same
  # NeuronDevice 0 as on trn2.3xlarge. The other model servers were shifted
  # to 8-15 (Whisper) / 16-31 (Qwen3-VL) / 32-63 (Qwen-Image-Edit) to keep
  # the layout fully non-overlapping on trn2.48xlarge.
  echo "4 0-3 /models/xttsv2-neuron-nxd-tp4"
}

# --- helper: run a YAML pipeline via the pipeline runner ---
#
# Mapping convention used by every consumer in this repo:
#   <dir>/tasks/<name>.json   <->   <dir>/pipelines/<name>/<name>.yml
#
# Callers pass the legacy task file path (still used to derive the YAML path
# by convention); the JSON file itself no longer needs to exist on disk.
run_task_json() {
  local task_file="$1"
  local vars_json="${2:-{\}}"
  local state_label="${3:-$(basename "$task_file" .json)}"

  # Source the dispatch helper lazily; we cd to REPO_ROOT before invoking
  # so the runner anchors .runner-state/ at a predictable spot.
  if ! declare -F pipeline_dispatch >/dev/null; then
    local helper="$REPO_ROOT/tools/pipeline-runner/lib-sh/dispatch.sh"
    if [[ ! -f "$helper" ]]; then
      err "dispatch helper missing at $helper"
      return 1
    fi
    export REPO_ROOT
    # shellcheck disable=SC1090
    source "$helper"
  fi

  local pipeline_name yml_path
  pipeline_name="$(basename "$task_file" .json)"
  yml_path="$(dirname "$(dirname "$task_file")")/pipelines/${pipeline_name}/${pipeline_name}.yml"

  if [[ "$DRY_RUN" == true ]]; then
    log "[dry] pipeline-runner: $yml_path on $EC2_INSTANCE_ID"
    return 0
  fi

  log "running pipeline: $pipeline_name on $EC2_INSTANCE_ID"
  pipeline_dispatch "$EC2_INSTANCE_ID" "$REGION" "" "$yml_path" "$vars_json" "$state_label"
}

# --- step: setup-efs-paths ---
step_setup_efs_paths() {
  section "setup-efs-paths"
  run_task_json "$SCRIPTS_TASKS/setup-efs-paths.json" "{}" setup-efs-paths
}

# --- step: migrate-to-efs ---
step_migrate_to_efs() {
  section "migrate-to-efs"
  TASK_MAX_WAIT_SECONDS=3600 \
    run_task_json "$SCRIPTS_TASKS/migrate-to-efs.json" "{}" migrate-to-efs
}

# --- step: whisper-precompile ---
# Switched to the NxD Inference path (TP=8). Legacy torch_neuronx.trace
# artefacts on EFS were wedged on a stale 3-tensor decoder signature; the
# NxD path keeps its artefacts under a separate prefix
# (/models/whisper-large-v3-neuron-nxd) so the two never collide.
step_whisper_precompile() {
  section "whisper-precompile (NxD)"
  local compile_url
  compile_url=$(stage_to_s3 "$REPO_ROOT/samples/models/whisper/compile_whisper_nxd.py" compile_whisper_nxd.py) || return 1
  local vars
  vars=$(jq -nc --arg url "$compile_url" '{COMPILE_SCRIPT_URL:$url}')
  TASK_MAX_WAIT_SECONDS=3600 \
    run_task_json "$WHISPER_TASKS/whisper-nxd-precompile.json" "$vars" whisper-nxd-precompile
}

# --- step: qwen3-vl-prepare ---
step_qwen3vl_prepare() {
  section "qwen3-vl-prepare"
  local tarball_url
  tarball_url=$(stage_dir_to_s3 "$REPO_ROOT/samples/models/qwen3-vl" qwen3-vl-source.tar.gz) || return 1
  local vars
  vars=$(jq -nc --arg url "$tarball_url" '{SOURCE_TARBALL_URL:$url}')
  TASK_MAX_WAIT_SECONDS=3600 \
    run_task_json "$QWEN3VL_TASKS/qwen3-vl-prepare.json" "$vars" qwen3-vl-prepare
}

# --- step: qwen-image-edit-prepare ---
step_qie_prepare() {
  section "qwen-image-edit-prepare"
  local tarball_url
  tarball_url=$(stage_dir_to_s3 "$REPO_ROOT/samples/models/qwen-image-edit" qwen-image-edit-source.tar.gz) || return 1
  local vars
  vars=$(jq -nc --arg url "$tarball_url" '{SOURCE_TARBALL_URL:$url}')
  TASK_MAX_WAIT_SECONDS=7200 \
    run_task_json "$QIE_TASKS/qwen-image-edit-prepare.json" "$vars" qwen-image-edit-prepare
}

# --- step: whisper-server ---
# Uses the NxD server (TP=8). Pinned to NeuronCores 8-15 by
# whisper-nxd-server.json; non-overlapping with xttsv2 (0-3), Qwen-Image-Edit (32-63)
# and Qwen3-VL (16-31). cores 8-15 require trn2.48xlarge (LNC=2 -> 64
# logical cores); on trn2.3xlarge / trn2.8xlarge override NEURON_CORES.
# The first health check on a freshly compiled model can take several
# minutes, so the upstream task allows up to 1800s.
step_whisper_server() {
  section "whisper-server (NxD)"
  local tarball_url
  tarball_url=$(stage_dir_to_s3 "$REPO_ROOT/samples/models/whisper" whisper-server-source.tar.gz) || return 1
  local vars
  vars=$(jq -nc --arg url "$tarball_url" '{SERVER_TARBALL_URL:$url}')
  TASK_MAX_WAIT_SECONDS=1800 \
    run_task_json "$WHISPER_TASKS/whisper-nxd-server.json" "$vars" whisper-nxd-server
}

# --- step: xttsv2-precompile ---
# XTTSv2 GPT decoder compile inside the SDK 2.28 DLC. The same source tarball
# carries compile_xttsv2_nxd.py + neuron_xttsv2/ + xttsv2_server.py +
# Dockerfile.server, so xttsv2-server can later re-extract it without
# restaging. The TP / cores / output path are picked per instance type by
# xttsv2_profile_for_instance() so /models stays clean across hosts that share
# the same EFS.
step_xttsv2_precompile() {
  section "xttsv2-precompile (DLC, BF16)"
  local tarball_url
  tarball_url=$(stage_dir_to_s3 "$XTTSV2_DIR" xttsv2-source.tar.gz) || return 1
  local profile xtts_tp xtts_cores xtts_path
  profile=$(xttsv2_profile_for_instance "$EC2_INSTANCE_TYPE")
  xtts_tp=$(awk '{print $1}' <<< "$profile")
  xtts_cores=$(awk '{print $2}' <<< "$profile")
  xtts_path=$(awk '{print $3}' <<< "$profile")
  log "xttsv2 profile: TP=$xtts_tp cores=$xtts_cores path=$xtts_path  (host=$EC2_INSTANCE_TYPE)"
  local vars
  vars=$(jq -nc \
    --arg url   "$tarball_url" \
    --arg tp    "$xtts_tp" \
    --arg cores "$xtts_cores" \
    --arg path  "$xtts_path" \
    '{SOURCE_TARBALL_URL:$url, TP_DEGREE:$tp, NEURON_CORES:$cores, COMPILED_MODEL_PATH:$path}')
  TASK_MAX_WAIT_SECONDS=7200 \
    run_task_json "$XTTSV2_TASKS/xttsv2-precompile.json" "$vars" xttsv2-precompile
}

# --- step: xttsv2-server ---
# Same per-instance profile as xttsv2-precompile so the server reads the right
# compiled artefact directory and pins to the cores that were actually
# compiled for. Health check waits up to 600s for warm-up.
step_xttsv2_server() {
  section "xttsv2-server (DLC)"
  local tarball_url
  tarball_url=$(stage_dir_to_s3 "$XTTSV2_DIR" xttsv2-source.tar.gz) || return 1
  local profile xtts_tp xtts_cores xtts_path
  profile=$(xttsv2_profile_for_instance "$EC2_INSTANCE_TYPE")
  xtts_tp=$(awk '{print $1}' <<< "$profile")
  xtts_cores=$(awk '{print $2}' <<< "$profile")
  xtts_path=$(awk '{print $3}' <<< "$profile")
  log "xttsv2 profile: TP=$xtts_tp cores=$xtts_cores path=$xtts_path  (host=$EC2_INSTANCE_TYPE)"
  local vars
  vars=$(jq -nc \
    --arg url   "$tarball_url" \
    --arg tp    "$xtts_tp" \
    --arg cores "$xtts_cores" \
    --arg path  "$xtts_path" \
    '{SOURCE_TARBALL_URL:$url, TP_DEGREE:$tp, NEURON_CORES:$cores, COMPILED_MODEL_PATH:$path}')
  TASK_MAX_WAIT_SECONDS=1800 \
    run_task_json "$XTTSV2_TASKS/xttsv2-server.json" "$vars" xttsv2-server
}

# --- step: qwen3-vl-server ---
step_qwen3vl_server() {
  section "qwen3-vl-server"
  local tarball_url
  tarball_url=$(stage_dir_to_s3 "$REPO_ROOT/samples/models/qwen3-vl" qwen3-vl-source.tar.gz) || return 1
  local vars
  vars=$(jq -nc --arg url "$tarball_url" '{SERVER_TARBALL_URL:$url}')
  TASK_MAX_WAIT_SECONDS=1800 \
    run_task_json "$QWEN3VL_TASKS/qwen3-vl-server.json" "$vars" qwen3-vl-server
}

# --- step: qwen-image-edit-server ---
step_qie_server() {
  section "qwen-image-edit-server"
  local tarball_url
  tarball_url=$(stage_dir_to_s3 "$REPO_ROOT/samples/models/qwen-image-edit" qwen-image-edit-source.tar.gz) || return 1
  local vars
  vars=$(jq -nc --arg url "$tarball_url" '{SOURCE_TARBALL_URL:$url}')
  TASK_MAX_WAIT_SECONDS=1800 \
    run_task_json "$QIE_TASKS/qwen-image-edit-server.json" "$vars" qwen-image-edit-server
}

# --- step: voice-image-edit-app (ApiStack/FrontendStack/StreamStack via deploy.sh) ---
step_voice_image_edit_app() {
  section "voice-image-edit-app"
  local asr_url="http://127.0.0.1:8765/transcribe"
  local vlm_url="http://127.0.0.1:8090/v1/chat/completions"
  local edit_url="http://127.0.0.1:8081/infer"
  local tts_url="http://127.0.0.1:8770/synthesize"
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry] cd $APP_INFRA_DIR && bash deploy.sh --base-stack-name $BASE_STACK_NAME --region $REGION --trainium-asr-url $asr_url --trainium-vlm-url $vlm_url --trainium-edit-url $edit_url --trainium-tts-url $tts_url"
    return 0
  fi
  local reset_args=()
  [[ "$RESET_APP_STACKS" == true ]] && reset_args+=(--reset-app-stacks)
  ( cd "$APP_INFRA_DIR" && bash deploy.sh \
    --base-stack-name "$BASE_STACK_NAME" \
    --region "$REGION" \
    --trainium-asr-url "$asr_url" \
    --trainium-vlm-url "$vlm_url" \
    --trainium-edit-url "$edit_url" \
    --trainium-tts-url "$tts_url" \
    "${reset_args[@]}" )
}

# --- step: neuron-anatomy (sibling stack, must follow EC2 recover) ---
# Re-runs the anatomy backend tarball deploy + CDK update so the
# NeuronAnatomyStack target group gets re-pointed at the current EC2's
# private IP. Without this step the anatomy ALB rule keeps the previous
# host's IP (which gets a new value on every recover) and /neuron/* goes
# 502 in the UI. We pass --only backend,infra to skip the optional
# integrate step (the frontend already has the NeuronDrawer mount).
step_neuron_anatomy() {
  section "neuron-anatomy"
  local anatomy_deploy="$REPO_ROOT/samples/neuron-anatomy/scripts/deploy.sh"
  if [[ ! -x "$anatomy_deploy" ]]; then
    warn "skip: $anatomy_deploy not found or not executable"
    return 0
  fi
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry] $anatomy_deploy --base-stack-name $BASE_STACK_NAME --region $REGION --only backend,infra"
    return 0
  fi
  bash "$anatomy_deploy" \
    --base-stack-name "$BASE_STACK_NAME" \
    --region "$REGION" \
    --only backend,infra
}

# --- helper: stage a single file or directory tar to the stage S3 bucket ---
# 出力: presigned URL (24h)
STAGE_BUCKET=""
ensure_stage_bucket() {
  if [[ -n "$STAGE_BUCKET" ]]; then return 0; fi
  # Pick any voice-image-edit-stage-* bucket whose LocationConstraint
  # matches $REGION. A bucket in another region will produce
  # SignatureMismatch when presigned via --region "$REGION", which
  # silently breaks `curl | tar -xzf` on the instance ("not in gzip
  # format"). We therefore explicitly verify each candidate's region
  # before adopting it.
  local candidates loc
  candidates=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'voice-image-edit-stage-')].Name" --output text)
  for cand in $candidates; do
    [[ -z "$cand" || "$cand" == "None" ]] && continue
    loc=$(aws s3api get-bucket-location --bucket "$cand" --query 'LocationConstraint' --output text 2>/dev/null || true)
    # us-east-1 reports None / null; everything else reports the region literal.
    if [[ "$loc" == "$REGION" || ( "$REGION" == "us-east-1" && ( "$loc" == "None" || "$loc" == "null" || -z "$loc" ) ) ]]; then
      STAGE_BUCKET="$cand"
      log "STAGE_BUCKET=$STAGE_BUCKET (region matched: $loc)"
      return 0
    fi
  done
  STAGE_BUCKET="voice-image-edit-stage-$(echo $REGION|tr -d '-')-$RANDOM-$RANDOM"
  log "creating stage bucket $STAGE_BUCKET in $REGION"
  if [[ "$REGION" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "$STAGE_BUCKET" --region "$REGION" >&2
  else
    aws s3api create-bucket --bucket "$STAGE_BUCKET" --region "$REGION" \
      --create-bucket-configuration "LocationConstraint=$REGION" >&2
  fi
  log "STAGE_BUCKET=$STAGE_BUCKET"
}

stage_to_s3() {
  local src="$1"
  local key="$2"
  ensure_stage_bucket
  aws s3 cp "$src" "s3://$STAGE_BUCKET/staging/$key" --no-progress >/dev/null
  aws s3 presign "s3://$STAGE_BUCKET/staging/$key" --expires-in 86400 --region "$REGION"
}

stage_dir_to_s3() {
  local dir="$1"
  local key="$2"
  ensure_stage_bucket
  local tmp
  tmp=$(mktemp /tmp/${key}.XXXXXX)
  ( cd "$dir" && tar --exclude='.git' --exclude='__pycache__' --exclude='*.pyc' --exclude='*.orig' --exclude='compile_cache' -czf "$tmp" . )
  aws s3 cp "$tmp" "s3://$STAGE_BUCKET/staging/$key" --no-progress >/dev/null
  rm -f "$tmp"
  aws s3 presign "s3://$STAGE_BUCKET/staging/$key" --expires-in 86400 --region "$REGION"
}

# --- main ---
# `precheck` populates EC2_INSTANCE_ID / EFS_ID / EC2_PUBLIC_IP from
# CloudFormation outputs and exports them. Every other step needs at
# least EC2_INSTANCE_ID to talk to the instance via SSM, so it must run
# unconditionally even when the operator scoped the run with --only.
# The check is read-only (describe-stacks + jq), so unconditional
# execution is safe and idempotent.
CURRENT_STEP="precheck"
step_precheck

START_TS=$(date +%s)
for step in "${ALL_STEPS[@]}"; do
  # precheck has already run above; skip it in the main loop regardless
  # of --only / --skip so we never describe-stacks twice.
  if [[ "$step" == "precheck" ]]; then
    continue
  fi
  if should_skip "$step"; then
    warn "skip: $step"
    continue
  fi
  CURRENT_STEP="$step"
  case "$step" in
    setup-efs-paths)         step_setup_efs_paths ;;
    migrate-to-efs)          step_migrate_to_efs ;;
    whisper-precompile)      step_whisper_precompile ;;
    qwen3-vl-prepare)        step_qwen3vl_prepare ;;
    qwen-image-edit-prepare) step_qie_prepare ;;
    xttsv2-precompile)       step_xttsv2_precompile ;;
    whisper-server)          step_whisper_server ;;
    qwen3-vl-server)         step_qwen3vl_server ;;
    qwen-image-edit-server)  step_qie_server ;;
    xttsv2-server)           step_xttsv2_server ;;
    voice-image-edit-app)    step_voice_image_edit_app ;;
    neuron-anatomy)          step_neuron_anatomy ;;
    *) err "unknown step: $step"; exit 1 ;;
  esac
done

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
ok "deploy-all finished in ${ELAPSED}s"
