#!/usr/bin/env bash
# voice-image-edit Stage 2 P9-D 補助スクリプト
#
# 目的:
#   既存 CloudFront distribution (neuron-ws-frontend stack 由来) に対して
#   /stream/* path 用の cache behavior を imperative に追加 / 復元する。
#
# 背景:
#   /stream/pipeline は SSE (text/event-stream) を返す。
#   default cache behavior は Compress=true / CachingOptimized なので、
#   long-lived chunked response が gzip 経路で詰まり ERR_HTTP2_PROTOCOL_ERROR
#   を引き起こす。/stream/* だけは下記設定が必要:
#     - Compress: false
#     - CachePolicy: Managed-CachingDisabled
#     - OriginRequestPolicy: Managed-AllViewerExceptHostHeader
#     - AllowedMethods: ALL (POST 含む)
#     - ViewerProtocolPolicy: redirect-to-https
#
# 注意:
#   neuron-ws-frontend stack の CloudFormation には反映しない (drift する)。
#   P9 の動作確認用途で、stack 再デプロイ時には消える前提。
#   revert は ./cf-stream-behavior.sh revert <distribution-id> で実行。
#
# 使い方:
#   apply  : ./cf-stream-behavior.sh apply  <distribution-id>
#   revert : ./cf-stream-behavior.sh revert <distribution-id>
#   status : ./cf-stream-behavior.sh status <distribution-id>
#
# Required: AWS_PROFILE=claude-code, jq, aws cli v2

set -euo pipefail

ACTION="${1:-}"
DIST_ID="${2:-}"
PATH_PATTERN="${PATH_PATTERN:-/stream/*}"

if [[ -z "$ACTION" || -z "$DIST_ID" ]]; then
  echo "Usage: $0 {apply|revert|status} <distribution-id>" >&2
  exit 2
fi

if [[ -z "${AWS_PROFILE:-}" ]]; then
  echo "[ERROR] AWS_PROFILE not set (claude-code を推奨)" >&2
  exit 2
fi

# Managed policy IDs (CloudFront global, region 非依存)
CACHE_POLICY_DISABLED="4135ea2d-6df8-44a3-9df3-4b5a84be39ad"
ORIGIN_REQ_ALL_VIEWER_EXCEPT_HOST="b689b0a8-53d0-40ab-baf2-68738e2966ac"

WORKDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKUP_DIR="$WORKDIR/.cf-backup"
mkdir -p "$BACKUP_DIR"
BACKUP_FILE="$BACKUP_DIR/$DIST_ID.json"

fetch_config() {
  aws cloudfront get-distribution-config --id "$DIST_ID" --output json
}

case "$ACTION" in
  status)
    fetch_config | jq -r --arg p "$PATH_PATTERN" '
      .DistributionConfig.CacheBehaviors.Items // []
      | map(select(.PathPattern == $p))
      | if length == 0 then "[NOT_PRESENT] " + $p
        else . | map({PathPattern, Compress, CachePolicyId, OriginRequestPolicyId, AllowedMethods: .AllowedMethods.Items})
             | "[PRESENT] " + ( . | tostring )
      end
    '
    ;;

  apply)
    CURRENT=$(fetch_config)
    ETAG=$(echo "$CURRENT" | jq -r '.ETag')

    # 既に存在するなら no-op
    if echo "$CURRENT" | jq -e --arg p "$PATH_PATTERN" '.DistributionConfig.CacheBehaviors.Items[]? | select(.PathPattern == $p)' >/dev/null; then
      echo "[OK] '$PATH_PATTERN' already present, no-op"
      exit 0
    fi

    # backup (revert 用)
    if [[ ! -f "$BACKUP_FILE" ]]; then
      echo "$CURRENT" > "$BACKUP_FILE"
      echo "[INFO] backup written: $BACKUP_FILE"
    else
      echo "[INFO] backup already exists: $BACKUP_FILE (kept)"
    fi

    # default behavior の TargetOriginId を流用 (ALB origin と同じにする)
    TARGET_ORIGIN_ID=$(echo "$CURRENT" | jq -r '.DistributionConfig.DefaultCacheBehavior.TargetOriginId')

    NEW_BEHAVIOR=$(jq -n \
      --arg pattern "$PATH_PATTERN" \
      --arg origin "$TARGET_ORIGIN_ID" \
      --arg cache_policy "$CACHE_POLICY_DISABLED" \
      --arg origin_req_policy "$ORIGIN_REQ_ALL_VIEWER_EXCEPT_HOST" \
      '{
        PathPattern: $pattern,
        TargetOriginId: $origin,
        ViewerProtocolPolicy: "redirect-to-https",
        AllowedMethods: {
          Quantity: 7,
          Items: ["HEAD","DELETE","POST","GET","OPTIONS","PUT","PATCH"],
          CachedMethods: { Quantity: 2, Items: ["HEAD","GET"] }
        },
        Compress: false,
        SmoothStreaming: false,
        FieldLevelEncryptionId: "",
        CachePolicyId: $cache_policy,
        OriginRequestPolicyId: $origin_req_policy,
        TrustedSigners: { Enabled: false, Quantity: 0 },
        TrustedKeyGroups: { Enabled: false, Quantity: 0 },
        LambdaFunctionAssociations: { Quantity: 0 },
        FunctionAssociations: { Quantity: 0 }
      }')

    NEW_CONFIG=$(echo "$CURRENT" | jq --argjson b "$NEW_BEHAVIOR" '
      .DistributionConfig
      | (.CacheBehaviors.Items //= [])
      | .CacheBehaviors.Items = ([$b] + .CacheBehaviors.Items)
      | .CacheBehaviors.Quantity = (.CacheBehaviors.Items | length)
    ')

    echo "$NEW_CONFIG" > "$BACKUP_DIR/$DIST_ID.applied.json"

    aws cloudfront update-distribution \
      --id "$DIST_ID" \
      --if-match "$ETAG" \
      --distribution-config "$NEW_CONFIG" \
      --query 'Distribution.Status' \
      --output text
    echo "[OK] '$PATH_PATTERN' added to distribution $DIST_ID"
    ;;

  revert)
    if [[ ! -f "$BACKUP_FILE" ]]; then
      echo "[ERROR] backup not found: $BACKUP_FILE" >&2
      echo "        cannot revert without baseline; use 'aws cloudfront update-distribution' manually" >&2
      exit 3
    fi
    ORIGINAL=$(cat "$BACKUP_FILE")
    CURRENT=$(fetch_config)
    ETAG=$(echo "$CURRENT" | jq -r '.ETag')
    ORIGINAL_CFG=$(echo "$ORIGINAL" | jq '.DistributionConfig')

    aws cloudfront update-distribution \
      --id "$DIST_ID" \
      --if-match "$ETAG" \
      --distribution-config "$ORIGINAL_CFG" \
      --query 'Distribution.Status' \
      --output text
    echo "[OK] reverted distribution $DIST_ID to baseline ($BACKUP_FILE)"
    ;;

  *)
    echo "Usage: $0 {apply|revert|status} <distribution-id>" >&2
    exit 2
    ;;
esac
