#!/usr/bin/env bash
# voice-image-edit Stage 2 P9-D 補助スクリプト
#
# 目的:
#   stream backend (EC2 8800 / uvicorn) が /stream/pipeline 内で
#   EDIT_API_BASE_URL = ALB internal DNS の /api/edit/* を呼ぶ際に、
#   ALB SG が CloudFront prefix list 経由しか受け付けない設定なので
#   EC2 -> ALB が SG で塞がれる。本スクリプトで EC2 SG -> ALB SG 80 を
#   apply / revert する。
#
# 使い方:
#   apply  : ./alb-sg-stream-ingress.sh apply  <alb-sg> <ec2-sg>
#   revert : ./alb-sg-stream-ingress.sh revert <alb-sg> <ec2-sg>
#   status : ./alb-sg-stream-ingress.sh status <alb-sg> <ec2-sg>
#
# 既定値: P9 環境
#   alb-sg = sg-0ccdb138f81426e3b
#   ec2-sg = sg-0cb00913ca0c675ef
#
# 注意:
#   描画の都合上 neuron-ws-alb stack の SG drift になる。stack 再デプロイ時に
#   消える可能性があるので、その場合は再 apply する。

set -euo pipefail

ACTION="${1:-}"
ALB_SG="${2:-sg-0ccdb138f81426e3b}"
EC2_SG="${3:-sg-0cb00913ca0c675ef}"
PORT="${PORT:-80}"
DESC="${DESC:-voice-image-edit stream EC2 to ALB for /api/edit/* (P9-D)}"

if [[ -z "$ACTION" ]]; then
  echo "Usage: $0 {apply|revert|status} [<alb-sg>] [<ec2-sg>]" >&2
  exit 2
fi
if [[ -z "${AWS_PROFILE:-}" ]]; then
  echo "[ERROR] AWS_PROFILE not set (claude-code を推奨)" >&2
  exit 2
fi

AWS_REGION="${AWS_REGION:-sa-east-1}"

find_rule() {
  aws ec2 describe-security-group-rules \
    --region "$AWS_REGION" \
    --filters Name=group-id,Values="$ALB_SG" \
    --query "SecurityGroupRules[?IsEgress==\`false\` && IpProtocol=='tcp' && FromPort==\`$PORT\` && ToPort==\`$PORT\` && ReferencedGroupInfo.GroupId=='$EC2_SG'].SecurityGroupRuleId" \
    --output text
}

case "$ACTION" in
  status)
    rid=$(find_rule)
    if [[ -n "$rid" && "$rid" != "None" ]]; then
      echo "[PRESENT] rule_id=$rid alb_sg=$ALB_SG <- ec2_sg=$EC2_SG :$PORT"
    else
      echo "[NOT_PRESENT] alb_sg=$ALB_SG <- ec2_sg=$EC2_SG :$PORT"
    fi
    ;;
  apply)
    rid=$(find_rule)
    if [[ -n "$rid" && "$rid" != "None" ]]; then
      echo "[OK] already present: $rid"
      exit 0
    fi
    aws ec2 authorize-security-group-ingress \
      --region "$AWS_REGION" \
      --group-id "$ALB_SG" \
      --ip-permissions "IpProtocol=tcp,FromPort=$PORT,ToPort=$PORT,UserIdGroupPairs=[{GroupId=$EC2_SG,Description=$DESC}]" \
      --query 'SecurityGroupRules[0].SecurityGroupRuleId' \
      --output text
    echo "[OK] alb_sg=$ALB_SG <- ec2_sg=$EC2_SG :$PORT added"
    ;;
  revert)
    rid=$(find_rule)
    if [[ -z "$rid" || "$rid" == "None" ]]; then
      echo "[OK] no matching rule, no-op"
      exit 0
    fi
    aws ec2 revoke-security-group-ingress \
      --region "$AWS_REGION" \
      --group-id "$ALB_SG" \
      --security-group-rule-ids "$rid" \
      --query 'Return' \
      --output text
    echo "[OK] revoked rule_id=$rid"
    ;;
  *)
    echo "Usage: $0 {apply|revert|status} [<alb-sg>] [<ec2-sg>]" >&2
    exit 2
    ;;
esac
