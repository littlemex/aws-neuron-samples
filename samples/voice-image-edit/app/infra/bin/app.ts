#!/usr/bin/env node
/**
 * voice-image-edit/app の CDK エントリポイント。
 *
 * このスタックは voice-image-edit のアプリケーション層 (api FastAPI + ALB rule + S3 +
 * frontend ALB rule + stream ALB rule) のみを扱う。CloudFront / Internal ALB / EC2 /
 * Cognito / EFS / Claude Code といった基盤レイヤは別途 setup/single-node/scripts/deploy.sh
 * が一撃でデプロイする想定。
 *
 * 二段デプロイの全体像:
 *   1) bash setup/single-node/scripts/deploy.sh --stack-name <base> ...
 *      -> CloudFront + ALB + Cognito + EC2 + EFS が一撃で立つ (本サンプル外)
 *   2) bash samples/voice-image-edit/app/infra/deploy.sh --base-stack-name <base> \
 *        --bedrock-region us-east-1
 *      -> 既存 ALB に api / frontend / stream の各 IP/instance Target を後付けし、
 *         EC2 instance role に Bedrock / Transcribe / S3 を attach する
 *
 * 履歴メモ (P10):
 *   旧 EditApiStack (Lambda Target) は ALB Lambda Target の 1 MB request/response 上限が
 *   画像 pipeline に構造的に合わず、P10 で ApiStack (EC2:8801 IP target) に置き換えた。
 *
 * 必須 context:
 *   - albArn, albListenerArn, albListenerSgId, albSecurityGroupId
 *   - originVerifyHeaderName, originVerifySecretArn
 *   - bedrockRegion
 *
 * 任意 context:
 *   - apiRegion (default = CDK_DEFAULT_REGION)
 *   - apiPort (default 8801), apiPathPattern (default /api/edit/*), apiRulePriority (default 100)
 *   - frontend* (FrontendStack を立てる場合に必要)
 *   - stream*   (StreamStack を立てる場合に必要)
 */
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { ApiStack } from '../lib/api-stack';
import { FrontendStack } from '../lib/frontend-stack';
import { StreamStack } from '../lib/stream-stack';

const app = new cdk.App();

const account = process.env.CDK_DEFAULT_ACCOUNT;
const apiRegion = (app.node.tryGetContext('apiRegion') as string | undefined) ?? process.env.CDK_DEFAULT_REGION;

if (!apiRegion) {
  throw new Error(
    'apiRegion (-c apiRegion=...) または CDK_DEFAULT_REGION の指定が必要です',
  );
}

// ApiStack は apiInstancePrivateIp などの追加 context が揃った時のみ deploy する。
// deploy.sh が --skip-api を指定しなければ立てる (default)。
const apiInstancePrivateIp = app.node.tryGetContext('apiInstancePrivateIp') as string | undefined;
if (apiInstancePrivateIp) {
  new ApiStack(app, 'VoiceImageEditApiStack', {
    env: { account, region: apiRegion },
    description:
      'voice-image-edit: api (FastAPI/uvicorn) ALB rule + IP-target Target Group (port 8801 on existing EC2). ' +
      'EC2 上での systemd 起動は deploy.sh が SSM run-tasks 経由で行う (P10 で Lambda 退役)',
  });
}

// Frontend stack は frontendInstanceId などの追加 context が揃った時のみ deploy する。
const frontendInstanceId = app.node.tryGetContext('frontendInstanceId') as string | undefined;
if (frontendInstanceId) {
  new FrontendStack(app, 'VoiceImageEditFrontendStack', {
    env: { account, region: apiRegion },
    description:
      'voice-image-edit: frontend (Next.js) ALB rule + Target Group (port 3000 on existing EC2). ' +
      'EC2 上での systemd 起動は deploy.sh が SSM run-tasks 経由で行う',
  });
}

// Stream stack も streamInstancePrivateIp などの追加 context が揃った時のみ deploy する。
const streamInstancePrivateIp = app.node.tryGetContext('streamInstancePrivateIp') as
  | string
  | undefined;
if (streamInstancePrivateIp) {
  new StreamStack(app, 'VoiceImageEditStreamStack', {
    env: { account, region: apiRegion },
    description:
      'voice-image-edit: streaming (SSE/WS) ALB rule + IP-target Target Group (port 8800 on existing EC2). ' +
      'EC2 上での uvicorn 常駐は deploy.sh が SSM run-tasks 経由で行う',
  });
}
