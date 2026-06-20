#!/usr/bin/env bash
#
# voice-image-edit one-shot deploy script (Stage 2 / 3 スロット abstraction 対応)。
#
# 既存の setup/single-node/scripts/deploy.sh で立てた基盤
# (CloudFront + Internal ALB + EC2 + Cognito + EFS) に対して、
# voice-image-edit のアプリケーション層 (api FastAPI + frontend + stream の ALB rule
# + EditResultBucket) を別スタック VoiceImageEdit{Api,Frontend,Stream}Stack として
# 後付けでデプロイする。
#
# 設計原則:
#   - 基盤 deploy.sh への runtime 依存ゼロ (CFn Outputs と describe-* のみ参照)。
#   - --base-stack-name <name> 1 つで一撃。ARN 上書きはデバッグ用。
#   - ハードコード禁止: 値は引数 / context / 基盤 stack outputs から取る。
#   - 3 スロット (ASR / VLM / EDIT) は --*-engine-default + --bedrock-*-model
#     + --trainium-*-url で個別に切り替え可能。
#
# P10 メモ:
#   旧 ALB Lambda Target は request/response とも 1MB 上限があり、画像 pipeline には
#   構造的に合わなかった。P10 で Lambda を退役させ、frontend / stream と同じ EC2 上に
#   systemd unit (voice-image-edit-api.service:8801) として常駐させる。
#   - 本スクリプトは ApiStack (IP target on EC2:8801) を deploy する
#   - api backend tarball は deploy 直後に build + S3 にアップロードして
#     presigned URL を生成し、SSM Run Command (run-tasks.sh) で systemd 起動する
#   - 旧 lambda zip ビルドは削除済み
#
# 必須:
#   --base-stack-name <name>      Stage 1 deploy.sh で渡した --stack-name と同じ名前
#                                 (デフォルト: neuron-code-server)
#
# 任意 (基盤接続):
#   -r, --region REGION                基盤 stack のリージョン (default: AWS_REGION / AWS_DEFAULT_REGION)
#   --bedrock-region REGION            Bedrock / Transcribe を呼ぶリージョン (default: us-east-1)
#   --generate-bedrock-region REGION   Stability text-to-image を呼ぶリージョン (default: us-west-2)
#   --edit-bedrock-region REGION       Stability image-to-image を呼ぶリージョン (default: us-west-2)
#   --polly-region REGION              Amazon Polly TTS を呼ぶリージョン (default: us-east-1)
#   --path-pattern PATTERN             ALB rule path (default: /api/edit/*)
#   --rule-priority N                  ALB rule priority (default: 100)
#   --api-port PORT                    API backend listen port (default: 8801)
#   --origin-verify-header NAME        default: X-Origin-Verify
#   --alb-arn ARN                      上書き (デバッグ用)
#   --listener-arn ARN                 上書き (デバッグ用)
#   --alb-security-group-id ID         上書き (デバッグ用)
#   --origin-verify-secret-arn ARN     上書き (デバッグ用)
#
# 任意 (3 スロット既定値):
#   --asr-engine-default NAME          default: trainium
#   --vlm-engine-default NAME          default: trainium
#   --edit-engine-default NAME         default: trainium
#
# 任意 (Bedrock model 上書き):
#   --bedrock-asr-backend BACKEND      transcribe / nova_sonic (default: transcribe)
#   --bedrock-claude-opus-model ID   default: us.anthropic.claude-opus-4-5-20251101-v1:0
#   --bedrock-nova-canvas-model ID     default: amazon.nova-canvas-v1:0
#   --trainium-edit-model-id ID        Trainium 自前 EDIT サーバが返す model id (default: Qwen/Qwen-Image-Edit-2511)
#
# 任意 (Trainium 自前サービング URL — 空なら trainium engine は config_missing):
#   --trainium-asr-url URL             例: http://internal-...:8000/transcribe
#   --trainium-vlm-url URL             例: http://internal-...:8090/v1/chat/completions
#   --trainium-edit-url URL            例: http://internal-...:8100/edit
#   --trainium-tts-url URL             例: http://127.0.0.1:8770/synthesize  (XTTSv2 NxD DLC)
#
# 操作:
#   --skip-api                    VoiceImageEditApiStack を deploy しない
#   --skip-api-deploy             ApiStack は deploy するが api tarball の SSM 配備を行わない
#   --skip-frontend               VoiceImageEditFrontendStack を deploy しない
#   --skip-frontend-deploy        FrontendStack は deploy するが frontend tarball の SSM 配備を行わない
#   --frontend-no-build           npm ci + npm run build をスキップし、既存 .next/standalone を使う
#   --frontend-port PORT          Next.js が listen するポート (default: 3000)
#   --frontend-rule-priority N    ALB Listener rule priority (default: 200)
#   --skip-stream                 VoiceImageEditStreamStack を deploy しない (P8 SSE 経路)
#   --skip-stream-deploy          StreamStack は deploy するが stream tarball の SSM 配備を行わない
#   --stream-port PORT            SSE backend が listen するポート (default: 8800)
#   --stream-rule-priority N      ALB Listener rule priority (default: 150)
#   --stream-path-pattern PATTERN ALB rule path (default: /stream/*)
#   --deploy-bucket BUCKET        tarball 配置用 S3 bucket (default: CDK bootstrap asset bucket を自動解決)
#   --reset-app-stacks            base ALB と紐づかない既存 VoiceImageEdit*Stack を deploy 前に強制 destroy。
#                                 base stack 再作成後の orphan stack を正規に作り直す唯一のパス。
#   --destroy                     全 stack を destroy する
#   --use-pipeline-runner         accepted for backward compatibility; YAML pipeline runner
#                                 is always used. CDK steps are unaffected.
#   -h, --help                    このヘルプ
#
# Examples:
#   bash deploy.sh --base-stack-name neuron-code-server --bedrock-region us-east-1
#   bash deploy.sh --base-stack-name neuron-code-server -r sa-east-1 \
#       --vlm-engine-default bedrock_claude_opus
#   bash deploy.sh --base-stack-name neuron-code-server --skip-frontend
#   bash deploy.sh --destroy --base-stack-name neuron-code-server

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# single source of truth: deploy-defaults.env を必ず source する。
# ここで `DEFAULT_*` 変数が export され、以下の `${X:-${DEFAULT_X}}` で受ける。
DEFAULTS_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/deploy-defaults.env"
if [[ ! -f "$DEFAULTS_FILE" ]]; then
    echo -e "\033[0;31m[NG] $DEFAULTS_FILE が見つかりません。voice-image-edit deploy の既定値はすべて同ファイルに集約されています。\033[0m" >&2
    exit 1
fi
# shellcheck disable=SC1090
source "$DEFAULTS_FILE"

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-}}"
BASE_STACK_NAME="neuron-code-server"
BEDROCK_REGION="${BEDROCK_REGION:-${DEFAULT_BEDROCK_REGION}}"
# Stability AI の text-to-image (Generate) と image-to-image (Edit) はいずれも
# us-west-2 のみで提供されているため、それぞれ独立した変数で持つ (リージョン
# 移行時に generate と edit を別々に動かせるようにするため)。
GENERATE_BEDROCK_REGION="${GENERATE_BEDROCK_REGION:-${DEFAULT_GENERATE_BEDROCK_REGION}}"
EDIT_BEDROCK_REGION="${EDIT_BEDROCK_REGION:-${DEFAULT_EDIT_BEDROCK_REGION}}"
# Polly Neural は sa-east-1 ではまだ GA していないため、Bedrock とは別経路で
# リージョンを指定可能にする。
POLLY_REGION="${POLLY_REGION:-${DEFAULT_POLLY_REGION}}"
PATH_PATTERN="${PATH_PATTERN:-${DEFAULT_API_PATH_PATTERN}}"
RULE_PRIORITY="${RULE_PRIORITY:-${DEFAULT_API_RULE_PRIORITY}}"
API_PORT="${API_PORT:-${DEFAULT_API_PORT}}"
ORIGIN_VERIFY_HEADER="${ORIGIN_VERIFY_HEADER:-${DEFAULT_ORIGIN_VERIFY_HEADER}}"

ASR_ENGINE_DEFAULT="${ASR_ENGINE_DEFAULT:-${DEFAULT_ASR_ENGINE}}"
VLM_ENGINE_DEFAULT="${VLM_ENGINE_DEFAULT:-${DEFAULT_VLM_ENGINE}}"
EDIT_ENGINE_DEFAULT="${EDIT_ENGINE_DEFAULT:-${DEFAULT_EDIT_ENGINE}}"

BEDROCK_ASR_BACKEND="${BEDROCK_ASR_BACKEND:-${DEFAULT_BEDROCK_ASR_BACKEND}}"
BEDROCK_CLAUDE_OPUS_MODEL_ID="${BEDROCK_CLAUDE_OPUS_MODEL_ID:-${DEFAULT_BEDROCK_CLAUDE_OPUS_MODEL_ID}}"
# VLM スロットの Bedrock は Claude Opus 1 本に集約済み (Nova Pro / Lite は撤廃)。
# 旧 BEDROCK_EDIT_MODEL_ID は撤廃。Nova Canvas を指す唯一の env は
# BEDROCK_NOVA_CANVAS_MODEL_ID に統一 (engines/edit/__init__.py がこれだけを読む)。
BEDROCK_NOVA_CANVAS_MODEL_ID="${BEDROCK_NOVA_CANVAS_MODEL_ID:-${DEFAULT_BEDROCK_NOVA_CANVAS_MODEL_ID}}"

TRAINIUM_ASR_URL=""
TRAINIUM_VLM_URL=""
TRAINIUM_EDIT_URL=""
TRAINIUM_TTS_URL=""
# Trainium 自前 EDIT サーバが返す model id (engines/edit/trainium.py のレスポンス
# metadata に乗る)。URL を渡すときと一緒に上書きする想定。
TRAINIUM_EDIT_MODEL_ID="${TRAINIUM_EDIT_MODEL_ID:-${DEFAULT_TRAINIUM_EDIT_MODEL_ID}}"

ALB_ARN_OVERRIDE=""
LISTENER_ARN_OVERRIDE=""
ALB_SG_ID_OVERRIDE=""
ORIGIN_VERIFY_SECRET_ARN_OVERRIDE=""
DEPLOY_BUCKET_OVERRIDE=""

SKIP_API=false
SKIP_API_DEPLOY=false
SKIP_FRONTEND=false
SKIP_FRONTEND_DEPLOY=false
FRONTEND_NO_BUILD=false
FRONTEND_PORT="${FRONTEND_PORT:-${DEFAULT_FRONTEND_PORT}}"
FRONTEND_RULE_PRIORITY="${FRONTEND_RULE_PRIORITY:-${DEFAULT_FRONTEND_RULE_PRIORITY}}"

SKIP_STREAM=false
SKIP_STREAM_DEPLOY=false
STREAM_PORT="${STREAM_PORT:-${DEFAULT_STREAM_PORT}}"
STREAM_RULE_PRIORITY="${STREAM_RULE_PRIORITY:-${DEFAULT_STREAM_RULE_PRIORITY}}"
STREAM_PATH_PATTERN="${STREAM_PATH_PATTERN:-${DEFAULT_STREAM_PATH_PATTERN}}"

RESET_APP_STACKS=false
DESTROY=false
# Accepted for backward compatibility; YAML pipeline runner is always used.
# CDK steps are unaffected.
USE_PIPELINE_RUNNER="${USE_PIPELINE_RUNNER:-true}"

usage() {
    sed -n '3,86p' "$0"
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --base-stack-name)              BASE_STACK_NAME="$2"; shift 2 ;;
        -r|--region)                    REGION="$2"; shift 2 ;;
        --bedrock-region)               BEDROCK_REGION="$2"; shift 2 ;;
        --generate-bedrock-region)      GENERATE_BEDROCK_REGION="$2"; shift 2 ;;
        --edit-bedrock-region)          EDIT_BEDROCK_REGION="$2"; shift 2 ;;
        --polly-region)                 POLLY_REGION="$2"; shift 2 ;;
        --path-pattern)                 PATH_PATTERN="$2"; shift 2 ;;
        --rule-priority)                RULE_PRIORITY="$2"; shift 2 ;;
        --api-port)                     API_PORT="$2"; shift 2 ;;
        --origin-verify-header)         ORIGIN_VERIFY_HEADER="$2"; shift 2 ;;
        --asr-engine-default)           ASR_ENGINE_DEFAULT="$2"; shift 2 ;;
        --vlm-engine-default)           VLM_ENGINE_DEFAULT="$2"; shift 2 ;;
        --edit-engine-default)          EDIT_ENGINE_DEFAULT="$2"; shift 2 ;;
        --bedrock-asr-backend)          BEDROCK_ASR_BACKEND="$2"; shift 2 ;;
        --bedrock-claude-opus-model)  BEDROCK_CLAUDE_OPUS_MODEL_ID="$2"; shift 2 ;;
        --bedrock-nova-canvas-model)    BEDROCK_NOVA_CANVAS_MODEL_ID="$2"; shift 2 ;;
        --bedrock-edit-model)
            # 後方互換: 旧フラグ名。BEDROCK_NOVA_CANVAS_MODEL_ID と同じ意味で受ける。
            BEDROCK_NOVA_CANVAS_MODEL_ID="$2"; shift 2 ;;
        --trainium-edit-model-id)       TRAINIUM_EDIT_MODEL_ID="$2"; shift 2 ;;
        --trainium-asr-url)             TRAINIUM_ASR_URL="$2"; shift 2 ;;
        --trainium-vlm-url)             TRAINIUM_VLM_URL="$2"; shift 2 ;;
        --trainium-edit-url)            TRAINIUM_EDIT_URL="$2"; shift 2 ;;
        --trainium-tts-url)             TRAINIUM_TTS_URL="$2"; shift 2 ;;
        --alb-arn)                      ALB_ARN_OVERRIDE="$2"; shift 2 ;;
        --listener-arn)                 LISTENER_ARN_OVERRIDE="$2"; shift 2 ;;
        --alb-security-group-id)        ALB_SG_ID_OVERRIDE="$2"; shift 2 ;;
        --origin-verify-secret-arn)     ORIGIN_VERIFY_SECRET_ARN_OVERRIDE="$2"; shift 2 ;;
        --deploy-bucket)                DEPLOY_BUCKET_OVERRIDE="$2"; shift 2 ;;
        --skip-api)                     SKIP_API=true; shift ;;
        --skip-api-deploy)              SKIP_API_DEPLOY=true; shift ;;
        --skip-frontend)                SKIP_FRONTEND=true; shift ;;
        --skip-frontend-deploy)         SKIP_FRONTEND_DEPLOY=true; shift ;;
        --frontend-no-build)            FRONTEND_NO_BUILD=true; shift ;;
        --frontend-port)                FRONTEND_PORT="$2"; shift 2 ;;
        --frontend-rule-priority)       FRONTEND_RULE_PRIORITY="$2"; shift 2 ;;
        --skip-stream)                  SKIP_STREAM=true; shift ;;
        --skip-stream-deploy)           SKIP_STREAM_DEPLOY=true; shift ;;
        --stream-port)                  STREAM_PORT="$2"; shift 2 ;;
        --stream-rule-priority)         STREAM_RULE_PRIORITY="$2"; shift 2 ;;
        --stream-path-pattern)          STREAM_PATH_PATTERN="$2"; shift 2 ;;
        --reset-app-stacks)             RESET_APP_STACKS=true; shift ;;
        --destroy)                      DESTROY=true; shift ;;
        --use-pipeline-runner)          shift ;;  # no-op: YAML runner is always used
        -h|--help)                      usage; exit 0 ;;
        *)
            echo -e "${RED}Error: unknown option: $1${NC}"
            usage; exit 1 ;;
    esac
done

if [[ -z "$REGION" ]]; then
    echo -e "${RED}[NG] --region (or AWS_REGION) is required${NC}"
    exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
    echo -e "${RED}[NG] aws CLI not found${NC}"; exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
    echo -e "${YELLOW}[WARN] jq not found; ALB introspection will use text output${NC}"
fi

PROFILE_ARG=()
if [[ -n "${AWS_PROFILE:-}" ]]; then
    PROFILE_ARG=(--profile "$AWS_PROFILE")
fi

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$INFRA_DIR"

# -----------------------------------------------------------------------------
# Resolve base stack outputs.
# -----------------------------------------------------------------------------
ALB_STACK_NAME="${BASE_STACK_NAME}-alb"

resolve_output() {
    local stack="$1" key="$2"
    aws cloudformation describe-stacks \
        --stack-name "$stack" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='${key}'].OutputValue" \
        --output text \
        "${PROFILE_ARG[@]}" 2>/dev/null || true
}

if [[ -n "$ALB_ARN_OVERRIDE" ]]; then
    ALB_ARN="$ALB_ARN_OVERRIDE"
else
    echo -e "${BLUE}[INFO] resolving AlbArn from ${ALB_STACK_NAME}${NC}"
    ALB_ARN="$(resolve_output "$ALB_STACK_NAME" "AlbArn")"
fi
if [[ -z "$ALB_ARN" || "$ALB_ARN" == "None" ]]; then
    echo -e "${RED}[NG] AlbArn is empty. Run setup/single-node/scripts/deploy.sh --create-alb-backend first, or pass --alb-arn.${NC}"
    exit 1
fi

if [[ -n "$ORIGIN_VERIFY_SECRET_ARN_OVERRIDE" ]]; then
    ORIGIN_VERIFY_SECRET_ARN="$ORIGIN_VERIFY_SECRET_ARN_OVERRIDE"
else
    ORIGIN_VERIFY_SECRET_ARN="$(resolve_output "$ALB_STACK_NAME" "OriginVerifySecretArn")"
fi
if [[ -z "$ORIGIN_VERIFY_SECRET_ARN" || "$ORIGIN_VERIFY_SECRET_ARN" == "None" ]]; then
    echo -e "${RED}[NG] OriginVerifySecretArn is empty. Pass --origin-verify-secret-arn or rerun base deploy.${NC}"
    exit 1
fi

if [[ -n "$LISTENER_ARN_OVERRIDE" ]]; then
    LISTENER_ARN="$LISTENER_ARN_OVERRIDE"
else
    LISTENER_ARN="$(aws elbv2 describe-listeners \
        --load-balancer-arn "$ALB_ARN" \
        --region "$REGION" \
        --query "Listeners[?Port==\`80\`].ListenerArn | [0]" \
        --output text \
        "${PROFILE_ARG[@]}" 2>/dev/null || true)"
fi
if [[ -z "$LISTENER_ARN" || "$LISTENER_ARN" == "None" ]]; then
    echo -e "${RED}[NG] Could not resolve HTTP:80 listener for ALB ${ALB_ARN}. Pass --listener-arn.${NC}"
    exit 1
fi

if [[ -n "$ALB_SG_ID_OVERRIDE" ]]; then
    ALB_SG_ID="$ALB_SG_ID_OVERRIDE"
else
    ALB_SG_ID="$(resolve_output "$ALB_STACK_NAME" "AlbSecurityGroupId")"
fi
if [[ -z "$ALB_SG_ID" || "$ALB_SG_ID" == "None" ]]; then
    ALB_SG_ID="$(aws elbv2 describe-load-balancers \
        --load-balancer-arns "$ALB_ARN" \
        --region "$REGION" \
        --query 'LoadBalancers[0].SecurityGroups[0]' \
        --output text \
        "${PROFILE_ARG[@]}" 2>/dev/null || true)"
fi
if [[ -z "$ALB_SG_ID" || "$ALB_SG_ID" == "None" ]]; then
    echo -e "${RED}[NG] Could not resolve ALB SecurityGroup id. Pass --alb-security-group-id.${NC}"
    exit 1
fi

# Origin verify secret read check (synth-time fail-fast)。
if ! aws secretsmanager get-secret-value \
        --secret-id "$ORIGIN_VERIFY_SECRET_ARN" \
        --region "$REGION" \
        --query 'SecretString' \
        --output text \
        "${PROFILE_ARG[@]}" >/dev/null 2>&1; then
    echo -e "${RED}[NG] OriginVerifySecret から値を取得できませんでした。secretsmanager:GetSecretValue 権限と ARN を確認してください${NC}"
    exit 1
fi

# -----------------------------------------------------------------------------
# base-stack identity drift detection
#
# Stage 2 stack (VoiceImageEdit{Api,Frontend,Stream}Stack) は CDK 上 base stack
# を import せず ALB ARN / Listener ARN を context 経由で受け取る。base stack を
# 作り直すと既存 Stage 2 stack は古い ALB ARN を参照したまま残る orphan になり、
# 次の cdk deploy で stale ARN を Secrets Manager / ListenerRule から触りに行って
# 醜い UPDATE_ROLLBACK_FAILED に落ちる。
#
# ここで既存 stack の ListenerRule ARN を覗いて ALB 名が現在の base ALB と
# 一致するかを事前検証する。不一致なら abort し、--reset-app-stacks で
# 明示的に再作成させる。
# -----------------------------------------------------------------------------
ALB_NAME="${ALB_ARN##*loadbalancer/app/}"
ALB_NAME="${ALB_NAME%%/*}"  # storea-Alb16-IF7NAZUgkkSP のような形式

stack_alb_name() {
    # 引数 stack の ListenerRule または TargetGroup の ARN を抽出して ALB 名を返す。
    # ListenerRule ARN: .../app/<alb-name>/<lb-id>/<listener-id>/<rule-id>
    # ALB が解決できない場合は空文字を返す。
    local stack="$1"
    local rule_arn
    rule_arn="$(aws cloudformation describe-stack-resources \
        --stack-name "$stack" \
        --region "$REGION" \
        --query "StackResources[?ResourceType=='AWS::ElasticLoadBalancingV2::ListenerRule'].PhysicalResourceId | [0]" \
        --output text \
        "${PROFILE_ARG[@]}" 2>/dev/null || true)"
    if [[ -z "$rule_arn" || "$rule_arn" == "None" ]]; then
        printf '%s' ""
        return 0
    fi
    local stripped="${rule_arn##*listener-rule/app/}"
    printf '%s' "${stripped%%/*}"
}

stack_exists() {
    local stack="$1"
    aws cloudformation describe-stacks \
        --stack-name "$stack" \
        --region "$REGION" \
        --query 'Stacks[0].StackStatus' \
        --output text \
        "${PROFILE_ARG[@]}" >/dev/null 2>&1
}

destroy_stack_if_present() {
    local stack="$1"
    if ! stack_exists "$stack"; then
        echo -e "${BLUE}[INFO] $stack は存在しないので skip${NC}"
        return 0
    fi
    echo -e "${YELLOW}[WARN] destroying orphan stack $stack${NC}"
    aws cloudformation delete-stack \
        --stack-name "$stack" \
        --region "$REGION" \
        "${PROFILE_ARG[@]}"
    if aws cloudformation wait stack-delete-complete \
            --stack-name "$stack" \
            --region "$REGION" \
            "${PROFILE_ARG[@]}"; then
        return 0
    fi

    # DELETE_FAILED に落ちた場合: orphan ALB Listener / TargetGroup / Rule は親 ALB ごと
    # 既に消えていることが多く、CFn から見ると外部削除済リソースになっている。
    # DELETE_FAILED のリソース一覧を取って --retain-resources で再 delete する。
    local failed_ids
    failed_ids="$(aws cloudformation describe-stack-resources \
        --stack-name "$stack" \
        --region "$REGION" \
        --query "StackResources[?ResourceStatus=='DELETE_FAILED'].LogicalResourceId" \
        --output text \
        "${PROFILE_ARG[@]}" 2>/dev/null || true)"
    if [[ -z "$failed_ids" ]]; then
        echo -e "${RED}[NG] $stack の削除に失敗 (DELETE_FAILED リソース無し)。${NC}" >&2
        exit 1
    fi
    echo -e "${YELLOW}[WARN] $stack: DELETE_FAILED リソース ($failed_ids) を retain して再 delete${NC}"
    # shellcheck disable=SC2086
    aws cloudformation delete-stack \
        --stack-name "$stack" \
        --region "$REGION" \
        --retain-resources $failed_ids \
        "${PROFILE_ARG[@]}"
    if ! aws cloudformation wait stack-delete-complete \
            --stack-name "$stack" \
            --region "$REGION" \
            "${PROFILE_ARG[@]}"; then
        echo -e "${RED}[NG] $stack の retain 付き削除も失敗。${NC}" >&2
        exit 1
    fi
}

# (詳細チェック実行) - 全 app stack について ALB 名を調べる
APP_STACK_NAMES=(VoiceImageEditApiStack VoiceImageEditFrontendStack VoiceImageEditStreamStack)
DRIFTED_STACKS=()
for s in "${APP_STACK_NAMES[@]}"; do
    if ! stack_exists "$s"; then
        continue
    fi
    existing_alb="$(stack_alb_name "$s")"
    if [[ -z "$existing_alb" ]]; then
        # ListenerRule が見つからない (rollback などで一部リソースだけが残っている異常状態)。
        echo -e "${YELLOW}[WARN] $s に ListenerRule が見つかりませんでした。drift 判定を保留。${NC}"
        continue
    fi
    if [[ "$existing_alb" != "$ALB_NAME" ]]; then
        echo -e "${YELLOW}[DRIFT] $s は ALB '${existing_alb}' を参照していますが、現在の base ALB は '${ALB_NAME}' です。${NC}"
        DRIFTED_STACKS+=("$s")
    fi
done

if [[ ${#DRIFTED_STACKS[@]} -gt 0 ]]; then
    echo
    echo -e "${RED}[NG] base ALB 不一致の orphan stack を検出しました:${NC}" >&2
    for s in "${DRIFTED_STACKS[@]}"; do
        echo -e "${RED}     - ${s}${NC}" >&2
    done
    echo -e "${RED}原因: base stack (${BASE_STACK_NAME}-alb) を作り直したが Stage 2 stack を destroy していないため。${NC}" >&2
    echo -e "${RED}対処: --reset-app-stacks を付けて再実行すると上記 orphan stack を destroy してから deploy します。${NC}" >&2
    if [[ "$RESET_APP_STACKS" != "true" ]]; then
        exit 1
    fi
    echo -e "${YELLOW}[INFO] --reset-app-stacks 指定: orphan stack を削除します${NC}"
    # 削除順は Frontend → Stream → Api (TG が ALB rule を保持する構造の逆順)。
    for s in VoiceImageEditFrontendStack VoiceImageEditStreamStack VoiceImageEditApiStack; do
        for d in "${DRIFTED_STACKS[@]}"; do
            if [[ "$s" == "$d" ]]; then
                destroy_stack_if_present "$s"
                break
            fi
        done
    done
fi

# -----------------------------------------------------------------------------
# Resolve EC2 instance + VPC + SG + IAM role (api / frontend / stream で共有)。
# Stage 1 base stack outputs InstanceId / SecurityGroupId.
# VPC / private IP / iam profile は describe-instances で resolve する。
# -----------------------------------------------------------------------------
EC2_INSTANCE_ID=""
EC2_INSTANCE_SG_ID=""
EC2_VPC_ID=""
EC2_PRIVATE_IP=""
EC2_INSTANCE_ROLE_NAME=""

NEEDS_EC2=false
if [[ "$SKIP_API" != "true" || "$SKIP_FRONTEND" != "true" || "$SKIP_STREAM" != "true" ]]; then
    NEEDS_EC2=true
fi

if [[ "$NEEDS_EC2" == "true" ]]; then
    EC2_INSTANCE_ID="$(resolve_output "$BASE_STACK_NAME" "InstanceId")"
    EC2_INSTANCE_SG_ID="$(resolve_output "$BASE_STACK_NAME" "SecurityGroupId")"
    if [[ -z "$EC2_INSTANCE_ID" || "$EC2_INSTANCE_ID" == "None" ]]; then
        echo -e "${RED}[NG] Could not resolve InstanceId from ${BASE_STACK_NAME}. Use --skip-api/--skip-frontend/--skip-stream or check Stage 1 outputs.${NC}"
        exit 1
    fi
    if [[ -z "$EC2_INSTANCE_SG_ID" || "$EC2_INSTANCE_SG_ID" == "None" ]]; then
        echo -e "${RED}[NG] Could not resolve SecurityGroupId from ${BASE_STACK_NAME}.${NC}"
        exit 1
    fi
    EC2_VPC_ID="$(aws ec2 describe-instances \
        --instance-ids "$EC2_INSTANCE_ID" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].VpcId' \
        --output text \
        "${PROFILE_ARG[@]}" 2>/dev/null || true)"
    EC2_PRIVATE_IP="$(aws ec2 describe-instances \
        --instance-ids "$EC2_INSTANCE_ID" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].PrivateIpAddress' \
        --output text \
        "${PROFILE_ARG[@]}" 2>/dev/null || true)"
    if [[ -z "$EC2_VPC_ID" || "$EC2_VPC_ID" == "None" ]]; then
        echo -e "${RED}[NG] Could not resolve VPC for instance ${EC2_INSTANCE_ID}.${NC}"
        exit 1
    fi
    if [[ -z "$EC2_PRIVATE_IP" || "$EC2_PRIVATE_IP" == "None" ]]; then
        echo -e "${RED}[NG] Could not resolve PrivateIpAddress for instance ${EC2_INSTANCE_ID}.${NC}"
        exit 1
    fi
    if [[ "$SKIP_API" != "true" ]]; then
        # IAM role を InstanceProfile 経由で resolve する (Stage 1 stack に直接 output が無いため)。
        IAM_PROFILE_ARN="$(aws ec2 describe-instances \
            --instance-ids "$EC2_INSTANCE_ID" \
            --region "$REGION" \
            --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
            --output text \
            "${PROFILE_ARG[@]}" 2>/dev/null || true)"
        if [[ -z "$IAM_PROFILE_ARN" || "$IAM_PROFILE_ARN" == "None" ]]; then
            echo -e "${RED}[NG] EC2 instance ${EC2_INSTANCE_ID} に IAM instance profile が attach されていません。${NC}"
            exit 1
        fi
        IAM_PROFILE_NAME="${IAM_PROFILE_ARN##*/}"
        EC2_INSTANCE_ROLE_NAME="$(aws iam get-instance-profile \
            --instance-profile-name "$IAM_PROFILE_NAME" \
            --query 'InstanceProfile.Roles[0].RoleName' \
            --output text \
            "${PROFILE_ARG[@]}" 2>/dev/null || true)"
        if [[ -z "$EC2_INSTANCE_ROLE_NAME" || "$EC2_INSTANCE_ROLE_NAME" == "None" ]]; then
            echo -e "${RED}[NG] InstanceProfile ${IAM_PROFILE_NAME} から Role 名を解決できませんでした。${NC}"
            exit 1
        fi
    fi
fi

echo -e "${GREEN}[OK] Resolved base stack outputs:${NC}"
echo "  Region                     : $REGION"
echo "  Base stack                 : $BASE_STACK_NAME"
echo "  ALB stack                  : $ALB_STACK_NAME"
echo "  AlbArn                     : $ALB_ARN"
echo "  ListenerArn (HTTP:80)      : $LISTENER_ARN"
echo "  AlbSecurityGroupId         : $ALB_SG_ID"
echo "  OriginVerifySecretArn      : $ORIGIN_VERIFY_SECRET_ARN"
echo "  OriginVerifyHeader         : $ORIGIN_VERIFY_HEADER"
echo "  BedrockRegion              : $BEDROCK_REGION"
echo "  GenerateBedrockRegion      : $GENERATE_BEDROCK_REGION"
echo "  EditBedrockRegion          : $EDIT_BEDROCK_REGION"
echo "  PollyRegion                : $POLLY_REGION"
echo
if [[ "$NEEDS_EC2" == "true" ]]; then
    echo "  Ec2 InstanceId             : $EC2_INSTANCE_ID"
    echo "  Ec2 PrivateIp              : $EC2_PRIVATE_IP"
    echo "  Ec2 SecurityGroupId        : $EC2_INSTANCE_SG_ID"
    echo "  Ec2 VpcId                  : $EC2_VPC_ID"
    if [[ "$SKIP_API" != "true" ]]; then
        echo "  Ec2 InstanceRoleName       : $EC2_INSTANCE_ROLE_NAME"
    fi
fi
echo
echo "  ASR default                : $ASR_ENGINE_DEFAULT  (bedrock backend: $BEDROCK_ASR_BACKEND)"
echo "  VLM default                : $VLM_ENGINE_DEFAULT"
echo "  EDIT default               : $EDIT_ENGINE_DEFAULT"
echo "  Bedrock Claude Opus (VLM)  : $BEDROCK_CLAUDE_OPUS_MODEL_ID"
echo "  Bedrock Nova Canvas (EDIT) : $BEDROCK_NOVA_CANVAS_MODEL_ID"
echo "  Trainium EDIT model id     : $TRAINIUM_EDIT_MODEL_ID"
echo "  Trainium ASR URL           : ${TRAINIUM_ASR_URL:-(none)}"
echo "  Trainium VLM URL           : ${TRAINIUM_VLM_URL:-(none)}"
echo "  Trainium EDIT URL          : ${TRAINIUM_EDIT_URL:-(none)}"
echo "  Trainium TTS URL           : ${TRAINIUM_TTS_URL:-(none)}"
if [[ "$SKIP_API" != "true" ]]; then
    echo "  Api PathPattern            : $PATH_PATTERN"
    echo "  Api RulePriority           : $RULE_PRIORITY"
    echo "  Api Port                   : $API_PORT"
else
    echo "  Api                        : SKIPPED (--skip-api)"
fi
if [[ "$SKIP_FRONTEND" != "true" ]]; then
    echo
    echo "  FrontendPort               : $FRONTEND_PORT"
    echo "  FrontendRulePriority       : $FRONTEND_RULE_PRIORITY"
    if [[ "$SKIP_FRONTEND_DEPLOY" == "true" ]]; then
        echo "  Frontend SSM deploy        : SKIPPED (--skip-frontend-deploy)"
    elif [[ "$FRONTEND_NO_BUILD" == "true" ]]; then
        echo "  Frontend build             : SKIPPED (--frontend-no-build, reuse existing .next/standalone)"
    fi
else
    echo "  Frontend                   : SKIPPED (--skip-frontend)"
fi
if [[ "$SKIP_STREAM" != "true" ]]; then
    echo
    echo "  StreamPort                 : $STREAM_PORT"
    echo "  StreamRulePriority         : $STREAM_RULE_PRIORITY"
    echo "  StreamPathPattern          : $STREAM_PATH_PATTERN"
    if [[ "$SKIP_STREAM_DEPLOY" == "true" ]]; then
        echo "  Stream SSM deploy          : SKIPPED (--skip-stream-deploy)"
    fi
else
    echo "  Stream                     : SKIPPED (--skip-stream)"
fi

# -----------------------------------------------------------------------------
# Install npm deps (idempotent).
# -----------------------------------------------------------------------------
if [[ ! -d "$INFRA_DIR/node_modules" ]]; then
    echo -e "${BLUE}[INFO] installing npm dependencies${NC}"
    (cd "$INFRA_DIR" && npm install --silent)
fi

# -----------------------------------------------------------------------------
# Build CDK context list.
# -----------------------------------------------------------------------------
CDK_CTX=(
    "-c" "apiRegion=$REGION"
    "-c" "albArn=$ALB_ARN"
    "-c" "albListenerArn=$LISTENER_ARN"
    "-c" "albListenerSgId=$ALB_SG_ID"
    "-c" "originVerifyHeaderName=$ORIGIN_VERIFY_HEADER"
    "-c" "originVerifySecretArn=$ORIGIN_VERIFY_SECRET_ARN"
    "-c" "bedrockRegion=$BEDROCK_REGION"
    "-c" "generateBedrockRegion=$GENERATE_BEDROCK_REGION"
    "-c" "editBedrockRegion=$EDIT_BEDROCK_REGION"
)

STACKS_TO_DEPLOY=()

# Api / Frontend / Stream はいずれも ALB SG ingress を生やすので albSecurityGroupId が必要。
if [[ "$NEEDS_EC2" == "true" ]]; then
    CDK_CTX+=("-c" "albSecurityGroupId=$ALB_SG_ID")
fi

if [[ "$SKIP_API" != "true" ]]; then
    CDK_CTX+=(
        "-c" "apiInstancePrivateIp=$EC2_PRIVATE_IP"
        "-c" "apiInstanceSgId=$EC2_INSTANCE_SG_ID"
        "-c" "apiInstanceRoleName=$EC2_INSTANCE_ROLE_NAME"
        "-c" "apiVpcId=$EC2_VPC_ID"
        "-c" "apiPort=$API_PORT"
        "-c" "apiPathPattern=$PATH_PATTERN"
        "-c" "apiRulePriority=$RULE_PRIORITY"
    )
    STACKS_TO_DEPLOY+=("VoiceImageEditApiStack")
fi

if [[ "$SKIP_FRONTEND" != "true" ]]; then
    CDK_CTX+=(
        "-c" "frontendInstanceId=$EC2_INSTANCE_ID"
        "-c" "frontendInstanceSgId=$EC2_INSTANCE_SG_ID"
        "-c" "frontendVpcId=$EC2_VPC_ID"
        "-c" "frontendPort=$FRONTEND_PORT"
        "-c" "frontendRulePriority=$FRONTEND_RULE_PRIORITY"
    )
    STACKS_TO_DEPLOY+=("VoiceImageEditFrontendStack")
fi

if [[ "$SKIP_STREAM" != "true" ]]; then
    CDK_CTX+=(
        "-c" "streamInstancePrivateIp=$EC2_PRIVATE_IP"
        "-c" "streamInstanceSgId=$EC2_INSTANCE_SG_ID"
        "-c" "streamVpcId=$EC2_VPC_ID"
        "-c" "streamPort=$STREAM_PORT"
        "-c" "streamRulePriority=$STREAM_RULE_PRIORITY"
        "-c" "streamPathPattern=$STREAM_PATH_PATTERN"
    )
    STACKS_TO_DEPLOY+=("VoiceImageEditStreamStack")
fi

if [[ ${#STACKS_TO_DEPLOY[@]} -eq 0 ]]; then
    echo -e "${YELLOW}[WARN] no stack selected (--skip-api/--skip-frontend/--skip-stream all set). Nothing to do.${NC}"
    exit 0
fi

export AWS_REGION="$REGION"
export AWS_DEFAULT_REGION="$REGION"

if [[ "$DESTROY" == "true" ]]; then
    echo -e "${YELLOW}[WARN] destroying ${STACKS_TO_DEPLOY[*]}${NC}"
    # Stream / Frontend / Api を逆順で消す (TG が ALB rule を保持していて削除順が狂うため)。
    REVERSED=()
    for ((i=${#STACKS_TO_DEPLOY[@]}-1; i>=0; i--)); do REVERSED+=("${STACKS_TO_DEPLOY[i]}"); done
    npx cdk destroy "${REVERSED[@]}" "${CDK_CTX[@]}" --force
    exit 0
fi

echo -e "${BLUE}[DEPLOY] ${STACKS_TO_DEPLOY[*]} -> ${REGION}${NC}"
npx cdk deploy "${STACKS_TO_DEPLOY[@]}" "${CDK_CTX[@]}" --require-approval never

# -----------------------------------------------------------------------------
# Show outputs.
# -----------------------------------------------------------------------------
echo
echo -e "${GREEN}[DONE] CDK stacks deployed.${NC}"

stack_out() {
    local stack="$1" key="$2"
    aws cloudformation describe-stacks \
        --stack-name "$stack" \
        --region "$REGION" \
        --query "Stacks[0].Outputs[?OutputKey=='$key'].OutputValue" \
        --output text \
        "${PROFILE_ARG[@]}" 2>/dev/null
}

API_RESULT_BUCKET=""
if [[ "$SKIP_API" != "true" ]]; then
    echo "  ApiTargetGroupArn          : $(stack_out VoiceImageEditApiStack ApiTargetGroupArn)"
    echo "  ApiInstancePrivateIp       : $(stack_out VoiceImageEditApiStack ApiInstancePrivateIp)"
    echo "  ApiPort                    : $(stack_out VoiceImageEditApiStack ApiPort)"
    echo "  ApiPathPattern             : $(stack_out VoiceImageEditApiStack ApiPathPattern)"
    echo "  ApiRulePriority            : $(stack_out VoiceImageEditApiStack ApiRulePriority)"
    API_RESULT_BUCKET="$(stack_out VoiceImageEditApiStack ApiResultBucketName)"
    echo "  ApiResultBucketName        : ${API_RESULT_BUCKET}"
fi

if [[ "$SKIP_FRONTEND" != "true" ]]; then
    echo "  FrontendTargetGroupArn     : $(stack_out VoiceImageEditFrontendStack FrontendTargetGroupArn)"
    echo "  FrontendInstanceId         : $(stack_out VoiceImageEditFrontendStack FrontendInstanceId)"
    echo "  FrontendPort               : $(stack_out VoiceImageEditFrontendStack FrontendPort)"
    echo "  FrontendRulePriority       : $(stack_out VoiceImageEditFrontendStack FrontendRulePriority)"
    echo "  FrontendPathPatterns       : $(stack_out VoiceImageEditFrontendStack FrontendPathPatterns)"
fi

if [[ "$SKIP_STREAM" != "true" ]]; then
    echo "  StreamTargetGroupArn       : $(stack_out VoiceImageEditStreamStack StreamTargetGroupArn)"
    echo "  StreamInstancePrivateIp    : $(stack_out VoiceImageEditStreamStack StreamInstancePrivateIp)"
    echo "  StreamPort                 : $(stack_out VoiceImageEditStreamStack StreamPort)"
    echo "  StreamPathPattern          : $(stack_out VoiceImageEditStreamStack StreamPathPattern)"
    echo "  StreamRulePriority         : $(stack_out VoiceImageEditStreamStack StreamRulePriority)"
fi

# -----------------------------------------------------------------------------
# Common helpers for tarball staging + SSM Run Command dispatch.
#   resolve_deploy_bucket            : resolve CDK bootstrap asset bucket once
#   stage_tarball <tar> <s3-prefix>  : upload to S3 and return presigned URL
#   run_task <instance> <task.json> <vars-json>
# -----------------------------------------------------------------------------
DEPLOY_BUCKET=""

resolve_deploy_bucket() {
    if [[ -n "$DEPLOY_BUCKET" ]]; then
        return 0
    fi
    DEPLOY_BUCKET="$DEPLOY_BUCKET_OVERRIDE"
    if [[ -z "$DEPLOY_BUCKET" ]]; then
        DEPLOY_BUCKET="$(aws cloudformation describe-stacks \
            --stack-name CDKToolkit \
            --region "$REGION" \
            --query "Stacks[0].Outputs[?OutputKey=='BucketName'].OutputValue" \
            --output text \
            "${PROFILE_ARG[@]}" 2>/dev/null || true)"
    fi
    if [[ -z "$DEPLOY_BUCKET" || "$DEPLOY_BUCKET" == "None" ]]; then
        echo -e "${RED}[NG] Could not resolve tarball upload bucket. Pass --deploy-bucket with a CDK-bootstrapped bucket name.${NC}" >&2
        exit 1
    fi
}

stage_tarball() {
    local local_tarball="$1" s3_prefix="$2"
    local key url size_hr
    key="${s3_prefix}/${s3_prefix}-$(date +%Y%m%d%H%M%S).tar.gz"
    size_hr="$(du -sh "$local_tarball" | awk '{print $1}')"
    echo -e "${BLUE}[INFO] uploading ${s3_prefix} tarball (${size_hr}) to s3://${DEPLOY_BUCKET}/${key}${NC}" >&2
    aws s3 cp "$local_tarball" "s3://${DEPLOY_BUCKET}/${key}" \
        --region "$REGION" \
        "${PROFILE_ARG[@]}" >/dev/null
    url="$(aws s3 presign "s3://${DEPLOY_BUCKET}/${key}" \
        --expires-in 1800 \
        --region "$REGION" \
        "${PROFILE_ARG[@]}")"
    printf '%s' "$url"
}

run_task() {
    # Dispatch a YAML pipeline via tools/pipeline-runner/lib-sh/dispatch.sh.
    # Convention: tasks/<name>.json -> pipelines/<name>/<name>.yml
    # The JSON file no longer needs to exist; only the YAML path is used.
    local instance_id="$1" legacy_json="$2" vars_json="$3" service="$4"

    local pipeline_name new_yml
    pipeline_name="$(basename "$legacy_json" .json)"
    new_yml="$INFRA_DIR/pipelines/${pipeline_name}/${pipeline_name}.yml"

    # Source the dispatch helper lazily.
    if ! declare -F pipeline_dispatch >/dev/null; then
        local helper="$INFRA_DIR/../../../../tools/pipeline-runner/lib-sh/dispatch.sh"
        if [[ ! -f "$helper" ]]; then
            echo -e "${RED}[NG] dispatch helper missing at $helper${NC}" >&2
            exit 1
        fi
        # REPO_ROOT anchors .runner-state/ at the repo root.
        export REPO_ROOT="$(cd "$INFRA_DIR/../../../.." && pwd)"
        # shellcheck disable=SC1090
        source "$helper"
    fi

    echo -e "${BLUE}[INFO] running ${pipeline_name}.yml via pipeline-runner on ${instance_id}${NC}"
    pipeline_dispatch "$instance_id" "$REGION" "" "$new_yml" "$vars_json" "$service"
}

# -----------------------------------------------------------------------------
# (1) API: build tarball + SSM dispatch (port 8801)。
# -----------------------------------------------------------------------------
deploy_api_service() {
    if [[ "$SKIP_API" == "true" || "$SKIP_API_DEPLOY" == "true" ]]; then
        echo -e "${BLUE}[INFO] skipping api backend systemd deploy (--skip-api or --skip-api-deploy).${NC}"
        return 0
    fi

    local api_dir="$INFRA_DIR/../backend/api"
    if [[ ! -f "$api_dir/app.py" ]]; then
        echo -e "${RED}[NG] $api_dir/app.py が見つかりません。--skip-api-deploy で skip するか repo を確認してください。${NC}" >&2
        exit 1
    fi

    resolve_deploy_bucket

    local tarball
    tarball="$(mktemp -t voice-image-edit-api.XXXXXX.tar.gz)"
    # shellcheck disable=SC2064
    trap "rm -f \"$tarball\"" RETURN

    (
        cd "$api_dir"
        tar --exclude='./.build' \
            --exclude='./__pycache__' \
            --exclude='*/__pycache__' \
            --exclude='./.pytest_cache' \
            --exclude='./tests' \
            -czf "$tarball" .
    )

    local presigned
    presigned="$(stage_tarball "$tarball" "voice-image-edit-api")"

    # EDIT 結果 S3 bucket は EC2 / ALB と同じ region (= $REGION) に CDK が作る。
    # api unit の AWS_REGION は Bedrock 用に us-east-1 を渡しているため、
    # EDIT_RESULT_REGION を明示しないと boto3 が us-east-1 で SigV4 署名して
    # bucket が us-east-2 だと SignatureDoesNotMatch / 403 になり presigned URL
    # が成立しない (P10 以降 task #89 で恒久対処)。
    local vars_json
    vars_json=$(jq -n \
        --arg api_tarball "$presigned" \
        --arg api_port "$API_PORT" \
        --arg aws_region "$REGION" \
        --arg bedrock_region "$BEDROCK_REGION" \
        --arg generate_bedrock_region "$GENERATE_BEDROCK_REGION" \
        --arg edit_bedrock_region "$EDIT_BEDROCK_REGION" \
        --arg polly_region "$POLLY_REGION" \
        --arg edit_bucket "$API_RESULT_BUCKET" \
        --arg edit_region "$REGION" \
        --arg asr "$ASR_ENGINE_DEFAULT" \
        --arg vlm "$VLM_ENGINE_DEFAULT" \
        --arg edit "$EDIT_ENGINE_DEFAULT" \
        --arg asr_backend "$BEDROCK_ASR_BACKEND" \
        --arg claude "$BEDROCK_CLAUDE_OPUS_MODEL_ID" \
        --arg nova_canvas "$BEDROCK_NOVA_CANVAS_MODEL_ID" \
        --arg trainium_asr "$TRAINIUM_ASR_URL" \
        --arg trainium_vlm "$TRAINIUM_VLM_URL" \
        --arg trainium_edit "$TRAINIUM_EDIT_URL" \
        --arg trainium_tts "$TRAINIUM_TTS_URL" \
        --arg trainium_edit_model "$TRAINIUM_EDIT_MODEL_ID" \
        '{
          API_TARBALL_URL: $api_tarball,
          API_PORT: $api_port,
          AWS_REGION: $aws_region,
          BEDROCK_REGION: $bedrock_region,
          GENERATE_BEDROCK_REGION: $generate_bedrock_region,
          EDIT_BEDROCK_REGION: $edit_bedrock_region,
          POLLY_REGION: $polly_region,
          EDIT_RESULT_BUCKET: $edit_bucket,
          EDIT_RESULT_REGION: $edit_region,
          ASR_ENGINE_DEFAULT: $asr,
          VLM_ENGINE_DEFAULT: $vlm,
          EDIT_ENGINE_DEFAULT: $edit,
          BEDROCK_ASR_BACKEND: $asr_backend,
          BEDROCK_CLAUDE_OPUS_MODEL_ID: $claude,
          BEDROCK_NOVA_CANVAS_MODEL_ID: $nova_canvas,
          BEDROCK_VLM_MODEL_ID: $claude,
          TRAINIUM_ASR_URL: $trainium_asr,
          TRAINIUM_VLM_URL: $trainium_vlm,
          TRAINIUM_EDIT_URL: $trainium_edit,
          TRAINIUM_TTS_URL: $trainium_tts,
          TRAINIUM_EDIT_MODEL_ID: $trainium_edit_model
        }')

    run_task "$EC2_INSTANCE_ID" "$INFRA_DIR/tasks/voice-image-edit-api.json" "$vars_json" "voice-image-edit-api"
    echo -e "${GREEN}[DONE] voice-image-edit-api.service is running on ${EC2_INSTANCE_ID}:${API_PORT}${NC}"
}

# -----------------------------------------------------------------------------
# (2) Frontend: Next.js standalone build → tarball → SSM dispatch (port 3000)。
#     Build 結果はホスト側で .next/standalone を組み立てて clean tarball を作る。
# -----------------------------------------------------------------------------
deploy_frontend_service() {
    if [[ "$SKIP_FRONTEND" == "true" || "$SKIP_FRONTEND_DEPLOY" == "true" ]]; then
        echo -e "${BLUE}[INFO] skipping frontend systemd deploy (--skip-frontend or --skip-frontend-deploy).${NC}"
        return 0
    fi

    local fe_dir="$INFRA_DIR/../frontend"
    if [[ ! -f "$fe_dir/package.json" ]]; then
        echo -e "${RED}[NG] $fe_dir/package.json が見つかりません。--skip-frontend-deploy で skip するか repo を確認してください。${NC}" >&2
        exit 1
    fi

    if ! command -v npm >/dev/null 2>&1; then
        echo -e "${RED}[NG] npm が見つかりません。Frontend ビルドには Node.js が必要です。${NC}" >&2
        exit 1
    fi

    resolve_deploy_bucket

    if [[ "$FRONTEND_NO_BUILD" != "true" ]]; then
        echo -e "${BLUE}[INFO] building frontend (next build, standalone) in ${fe_dir}${NC}"
        (
            cd "$fe_dir"
            # Run npm ci unconditionally (not just when node_modules is
            # absent). file: dependencies that landed via npm install on a
            # developer machine remain in node_modules even after the
            # underlying source moved or the package was renamed; only npm
            # ci against the lock file recreates the correct symlinks.
            npm ci --silent
            npm run build
        )
    else
        echo -e "${YELLOW}[WARN] --frontend-no-build: skipping npm build, using existing .next/standalone${NC}"
    fi

    if [[ ! -f "$fe_dir/.next/standalone/server.js" ]]; then
        echo -e "${RED}[NG] $fe_dir/.next/standalone/server.js が見つかりません。next.config.mjs の output: 'standalone' を確認してください。${NC}" >&2
        exit 1
    fi

    # standalone server.js に .next/static と public を結合した tarball を作る (Next.js 公式手順)。
    local stage_dir tarball
    stage_dir="$(mktemp -d -t voice-image-edit-frontend.XXXXXX)"
    tarball="$(mktemp -t voice-image-edit-frontend.XXXXXX.tar.gz)"
    # shellcheck disable=SC2064
    trap "rm -rf \"$stage_dir\" \"$tarball\"" RETURN

    cp -R "$fe_dir/.next/standalone/." "$stage_dir/"
    mkdir -p "$stage_dir/.next"
    cp -R "$fe_dir/.next/static" "$stage_dir/.next/static"
    if [[ -d "$fe_dir/public" ]]; then
        cp -R "$fe_dir/public" "$stage_dir/public"
    fi
    tar -C "$stage_dir" -czf "$tarball" .

    local presigned
    presigned="$(stage_tarball "$tarball" "voice-image-edit-frontend")"

    local vars_json
    vars_json=$(jq -n \
        --arg url "$presigned" \
        --arg port "$FRONTEND_PORT" \
        '{
          FRONTEND_TARBALL_URL: $url,
          FRONTEND_PORT: $port
        }')

    run_task "$EC2_INSTANCE_ID" "$INFRA_DIR/tasks/voice-image-edit-frontend.json" "$vars_json" "voice-image-edit-frontend"
    echo -e "${GREEN}[DONE] voice-image-edit-frontend.service is running on ${EC2_INSTANCE_ID}:${FRONTEND_PORT}${NC}"
}

# -----------------------------------------------------------------------------
# (3) Stream (SSE backend): tarball → SSM dispatch (port 8800)。
#     EDIT_API_BASE_URL は internal ALB DNS、ORIGIN_VERIFY_HEADER_VALUE は
#     Secrets Manager から実行時に取得して systemd Environment 経由でだけ渡す
#     (ターミナル / ログには出さない)。
# -----------------------------------------------------------------------------
deploy_stream_service() {
    if [[ "$SKIP_STREAM" == "true" || "$SKIP_STREAM_DEPLOY" == "true" ]]; then
        echo -e "${BLUE}[INFO] skipping stream backend systemd deploy (--skip-stream or --skip-stream-deploy).${NC}"
        return 0
    fi

    local stream_dir="$INFRA_DIR/../backend/stream"
    if [[ ! -f "$stream_dir/app.py" ]]; then
        echo -e "${RED}[NG] $stream_dir/app.py が見つかりません。--skip-stream-deploy で skip するか repo を確認してください。${NC}" >&2
        exit 1
    fi

    resolve_deploy_bucket

    local tarball
    tarball="$(mktemp -t voice-image-edit-stream.XXXXXX.tar.gz)"
    # shellcheck disable=SC2064
    trap "rm -f \"$tarball\"" RETURN

    (
        cd "$stream_dir"
        tar --exclude='./.build' \
            --exclude='./__pycache__' \
            --exclude='*/__pycache__' \
            --exclude='./.pytest_cache' \
            --exclude='./tests' \
            -czf "$tarball" .
    )

    local presigned
    presigned="$(stage_tarball "$tarball" "voice-image-edit-stream")"

    # ALB DNS を Stage 1 alb stack output から取る (CDK で AlbDnsName が export 済み)。
    local alb_dns
    alb_dns="$(resolve_output "$ALB_STACK_NAME" "AlbDnsName")"
    if [[ -z "$alb_dns" || "$alb_dns" == "None" ]]; then
        echo -e "${RED}[NG] AlbDnsName を ${ALB_STACK_NAME} から解決できませんでした。${NC}" >&2
        exit 1
    fi
    # PATH_PATTERN は "/api/edit/*" のような末尾 /* を含む形式なので接尾辞を剥がして付与する。
    # stream backend は EDIT_API_BASE_URL + "/vlm" のように path を結合するため、
    # base に /api/edit までを必ず含める必要がある (含めないと ALB rule にマッチせず default 403/413 になる)。
    local api_path_prefix="${PATH_PATTERN%/\*}"
    local edit_api_base="http://${alb_dns}${api_path_prefix}"

    # Origin verify ヘッダ値を Secrets Manager から取り出す (output には残さない)。
    local ov_value
    ov_value="$(aws secretsmanager get-secret-value \
        --secret-id "$ORIGIN_VERIFY_SECRET_ARN" \
        --region "$REGION" \
        --query 'SecretString' \
        --output text \
        "${PROFILE_ARG[@]}" 2>/dev/null || true)"
    if [[ -z "$ov_value" || "$ov_value" == "None" ]]; then
        echo -e "${RED}[NG] OriginVerifySecret から値を取得できませんでした (deploy 直前は §pre-check で読めていたはず)。${NC}" >&2
        exit 1
    fi

    # jq の --arg は echo されないので secret 値が stdout / set -x に乗らない。
    local vars_json
    vars_json=$(jq -n \
        --arg url "$presigned" \
        --arg port "$STREAM_PORT" \
        --arg base "$edit_api_base" \
        --arg ov_name "$ORIGIN_VERIFY_HEADER" \
        --arg ov_value "$ov_value" \
        '{
          STREAM_TARBALL_URL: $url,
          STREAM_PORT: $port,
          EDIT_API_BASE_URL: $base,
          ORIGIN_VERIFY_HEADER_NAME: $ov_name,
          ORIGIN_VERIFY_HEADER_VALUE: $ov_value
        }')
    unset ov_value

    run_task "$EC2_INSTANCE_ID" "$INFRA_DIR/tasks/voice-image-edit-stream.json" "$vars_json" "voice-image-edit-stream"
    echo -e "${GREEN}[DONE] voice-image-edit-stream.service is running on ${EC2_INSTANCE_ID}:${STREAM_PORT}${NC}"

    # --------------------------------------------------------------
    # EC2 -> ALB :80 ingress for the stream backend's edit-API calls.
    # --------------------------------------------------------------
    # The stream backend drives the edit pipeline (ASR -> vlm_instruction
    # -> edit -> vlm_review) by calling EDIT_API_BASE_URL, which is the
    # INTERNAL ALB DNS. The ALB SG only allows :80 from the CloudFront
    # origin-facing prefix list, so the EC2 -> ALB hop is blocked by
    # default and vlm_instruction hangs until timeout ("指示生成 stalls").
    # This rule was previously applied by hand via alb-sg-stream-ingress.sh
    # and was lost on every instance/ALB replacement. Apply it here so a
    # fresh deploy or a --recover restores it automatically. Idempotent:
    # the helper is a no-op when the rule already exists.
    local _sg_helper="$INFRA_DIR/scripts/alb-sg-stream-ingress.sh"
    if [[ -x "$_sg_helper" ]] && [[ -n "$ALB_SG_ID" && "$ALB_SG_ID" != "None" ]] && \
       [[ -n "$EC2_INSTANCE_SG_ID" && "$EC2_INSTANCE_SG_ID" != "None" ]]; then
        echo -e "${BLUE}[STREAM-SG] Ensuring EC2 SG -> ALB SG :80 ingress (stream -> edit API)${NC}"
        AWS_REGION="$REGION" AWS_DEFAULT_REGION="$REGION" \
            bash "$_sg_helper" apply "$ALB_SG_ID" "$EC2_INSTANCE_SG_ID" || \
            echo -e "${YELLOW}[WARN] stream->ALB ingress apply failed; the edit pipeline (指示生成) may stall.${NC}"
    else
        echo -e "${YELLOW}[WARN] Cannot ensure stream->ALB ingress (helper or SG ids missing).${NC}"
        echo -e "${YELLOW}       Run: bash $_sg_helper apply <alb-sg> <ec2-sg>${NC}"
    fi
}

echo
deploy_api_service
echo
deploy_frontend_service
echo
deploy_stream_service

echo
echo -e "${GREEN}[DONE] application services deployed.${NC}"
echo
echo "Smoke tests (CloudFront 経由 + Cognito cookie が必要):"
if [[ "$SKIP_API" != "true" ]]; then
    echo "  curl -sS https://<cloudfront-domain>${PATH_PATTERN%/*}/health  --cookie 'cf_session=...'"
    echo "  curl -sS https://<cloudfront-domain>${PATH_PATTERN%/*}/engines --cookie 'cf_session=...'"
fi
if [[ "$SKIP_FRONTEND" != "true" ]]; then
    echo "  curl -sS https://<cloudfront-domain>/edit --cookie 'cf_session=...'"
fi
if [[ "$SKIP_STREAM" != "true" ]]; then
    echo "  curl -sN https://<cloudfront-domain>${STREAM_PATH_PATTERN%/*}/health --cookie 'cf_session=...'"
    echo "  curl -sN \"https://<cloudfront-domain>${STREAM_PATH_PATTERN%/*}/echo?count=3&interval_ms=200\" --cookie 'cf_session=...'"
fi
