#!/bin/bash
# voice-image-edit one-shot deploy
#
# このスクリプトは以下を順次実行する。 各 step は idempotent で、
# CodeBuild Capacity Block / Spot terminate 後に再実行しても、
# キャッシュ済みの artifact (Neuron compile, HF download, NEFF cache) を
# 再利用してサービングを再開できることを目指す。
#
#   precheck            base stack output / EFS mount / NeuronCore を確認
#   setup-efs-paths     /models, /opt/voice-image-edit, compile artifact dir を EFS に向ける symlink layer
#   whisper-precompile  encoder/decoder/proj.pt を EFS に compile (cache hit で skip)
#   qwen3-vl-prepare    weights + warmup artifact を EFS に置く (cache hit で skip)
#   qwen-image-edit-prepare V3 CFG 5 component を EFS に compile (cache hit で skip)
#   whisper-server      systemd unit install + start (port 8765)
#   qwen3-vl-server     systemd unit install + start (port 8090)
#   qwen-image-edit-server systemd unit install + start (port 8081)
#   voice-image-edit-app  ApiStack/FrontendStack/StreamStack に TRAINIUM_*_URL を inject
#
# 使い方:
#   bash deploy-all.sh \
#     --base-stack-name storeai-validation-use2 \
#     --region us-east-2
#
# 主な flag:
#   --base-stack-name   base stack 名 (EC2 インスタンスや EFS mount 情報を output から拾う)
#   --region            AWS region (default: us-east-2)
#   --skip <names>      , 区切りで step を skip ("setup-efs-paths,migrate-to-efs" など)
#   --only <names>      , 区切りで指定 step のみ実行 (debug 用)
#   --migrate           初回 EFS 移行で migrate-to-efs を setup-efs-paths の前に挟む
#   --recover           CB / Spot terminate 後の recovery mode (= --skip migrate-to-efs と同義、 default)
#   --dry-run           各 step の表示のみ。 SSM 送信は走らない
#
# 必須環境変数:
#   AWS_PROFILE=claude-code  (他 profile 禁止: 2026-04-20 厳命)
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

# Step granularity: --skip prepare で 3 prepare 全部 skip / --skip setup-efs-paths で 1 step skip
ALL_STEPS=(
  precheck
  setup-efs-paths
  migrate-to-efs
  whisper-precompile
  qwen3-vl-prepare
  qwen-image-edit-prepare
  whisper-server
  qwen3-vl-server
  qwen-image-edit-server
  voice-image-edit-app
)

while [[ $# -gt 0 ]]; do
  case $1 in
    --base-stack-name) BASE_STACK_NAME="$2"; shift 2 ;;
    --region)          REGION="$2"; shift 2 ;;
    --skip)            SKIP_STEPS="$2"; shift 2 ;;
    --only)            ONLY_STEPS="$2"; shift 2 ;;
    --migrate)         MIGRATE=true; shift ;;
    --recover)         MIGRATE=false; shift ;;
    --dry-run)         DRY_RUN=true; shift ;;
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
RUNNER="$REPO_ROOT/setup/single-node/scripts/run-tasks.sh"
WHISPER_TASKS="$REPO_ROOT/samples/models/whisper/tasks"
QWEN3VL_TASKS="$REPO_ROOT/samples/models/qwen3-vl/tasks"
QIE_TASKS="$REPO_ROOT/samples/models/qwen-image-edit/tasks"
SCRIPTS_TASKS="$VIE_DIR/scripts/tasks"
APP_INFRA_DIR="$VIE_DIR/app/infra"

[[ -x "$RUNNER" ]] || { err "$RUNNER missing or not executable"; exit 1; }

log "REPO_ROOT=$REPO_ROOT"
log "RUNNER=$RUNNER"
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
  export EC2_INSTANCE_ID EC2_PUBLIC_IP EFS_ID
}

# --- helper: run a task JSON via run-tasks.sh ---
run_task_json() {
  local task_file="$1"
  local vars_json="${2:-{\}}"
  local state_label="${3:-$(basename "$task_file" .json)}"
  local state_file="/tmp/task-state-${EC2_INSTANCE_ID}-${state_label}.json"
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry] $RUNNER -i $EC2_INSTANCE_ID -r $REGION -f $task_file -v '$vars_json' --state-file $state_file"
    return 0
  fi
  log "running: $task_file (state=$state_file)"
  "$RUNNER" \
    -i "$EC2_INSTANCE_ID" \
    -r "$REGION" \
    -f "$task_file" \
    -v "$vars_json" \
    --state-file "$state_file"
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
# Uses the NxD server (TP=8). Pinned to NeuronCores 24-39 by
# whisper-nxd-server.json; non-overlapping with Qwen3-VL (0-15) and
# Qwen-Image-Edit (16-23). The first health check on a freshly compiled
# model can take several minutes, so the upstream task allows 600s.
step_whisper_server() {
  section "whisper-server (NxD)"
  local tarball_url
  tarball_url=$(stage_dir_to_s3 "$REPO_ROOT/samples/models/whisper" whisper-server-source.tar.gz) || return 1
  local vars
  vars=$(jq -nc --arg url "$tarball_url" '{SERVER_TARBALL_URL:$url}')
  TASK_MAX_WAIT_SECONDS=1800 \
    run_task_json "$WHISPER_TASKS/whisper-nxd-server.json" "$vars" whisper-nxd-server
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
  if [[ "$DRY_RUN" == true ]]; then
    log "[dry] cd $APP_INFRA_DIR && bash deploy.sh --base-stack-name $BASE_STACK_NAME --region $REGION --trainium-asr-url $asr_url --trainium-vlm-url $vlm_url --trainium-edit-url $edit_url"
    return 0
  fi
  ( cd "$APP_INFRA_DIR" && bash deploy.sh \
    --base-stack-name "$BASE_STACK_NAME" \
    --region "$REGION" \
    --trainium-asr-url "$asr_url" \
    --trainium-vlm-url "$vlm_url" \
    --trainium-edit-url "$edit_url" )
}

# --- helper: stage a single file or directory tar to the stage S3 bucket ---
# 出力: presigned URL (24h)
STAGE_BUCKET=""
ensure_stage_bucket() {
  if [[ -n "$STAGE_BUCKET" ]]; then return 0; fi
  # voice-image-edit-stage-<region>-<random> から既存を 1 つ拾う。 無ければ作る。
  STAGE_BUCKET=$(aws s3api list-buckets --query "Buckets[?starts_with(Name,'voice-image-edit-stage-')].Name | [0]" --output text)
  if [[ "$STAGE_BUCKET" == "None" || -z "$STAGE_BUCKET" ]]; then
    STAGE_BUCKET="voice-image-edit-stage-$(echo $REGION|tr -d '-')-$RANDOM-$RANDOM"
    log "creating stage bucket $STAGE_BUCKET"
    aws s3 mb "s3://$STAGE_BUCKET" --region "$REGION" >&2
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
    whisper-server)          step_whisper_server ;;
    qwen3-vl-server)         step_qwen3vl_server ;;
    qwen-image-edit-server)  step_qie_server ;;
    voice-image-edit-app)    step_voice_image_edit_app ;;
    *) err "unknown step: $step"; exit 1 ;;
  esac
done

END_TS=$(date +%s)
ELAPSED=$((END_TS - START_TS))
ok "deploy-all finished in ${ELAPSED}s"
