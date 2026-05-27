#!/usr/bin/env node
import 'source-map-support/register';
import * as cdk from 'aws-cdk-lib';
import { NeuronCodeServerStack } from '../lib/torch-neuron-stack';
import { EfsPersistenceStack } from '../lib/efs-persistence-stack';
import { AlbBackendStack } from '../lib/alb-backend-stack';
import { CognitoOperatorStack } from '../lib/cognito-operator-stack';
import { CloudFrontFrontendStack } from '../lib/cloudfront-frontend-stack';

const app = new cdk.App();

const stackName = app.node.tryGetContext('stackName') || 'neuron-code-server';
const instanceType = app.node.tryGetContext('instanceType') || 'trn2.3xlarge';
const useCapacityBlock = app.node.tryGetContext('useCapacityBlock') === 'true';
const capacityReservationId = app.node.tryGetContext('capacityReservationId') || '';
const useSpot = app.node.tryGetContext('useSpot') === 'true';
const spotMaxPrice = app.node.tryGetContext('spotMaxPrice') || '';
const spotInterruptionBehavior =
  app.node.tryGetContext('spotInterruptionBehavior') || 'terminate';
const subnetId = app.node.tryGetContext('subnetId') || '';
const volumeSize = parseInt(app.node.tryGetContext('volumeSize') || '500');
const efsId = app.node.tryGetContext('efsId') || '';
const efsSubpath = app.node.tryGetContext('efsSubpath') || '/neuron-workspace';
const installClaudeCode = app.node.tryGetContext('installClaudeCode') === 'true';
const project = app.node.tryGetContext('project') || '';
const purpose = app.node.tryGetContext('purpose') || '';
const forceRecreateToken = app.node.tryGetContext('forceRecreateToken') || '';

if (useCapacityBlock && useSpot) {
  throw new Error(
    'useCapacityBlock and useSpot are mutually exclusive. Choose one.'
  );
}

// ---------------------------------------------------------------------------
// Optional: EFS persistence stack (opt-in via -c createEfs=true).
// When enabled, this stack creates an EFS file system + per-AZ mount targets
// in the default VPC. The EFS lifecycle is intentionally independent of the
// EC2 host so a Spot reclaim does not lose compiled NEFF caches or HF model
// downloads. deploy.sh authorizes NFS (TCP 2049) ingress on the EFS mount
// target SG for the EC2 instance SG after both stacks are up.
// ---------------------------------------------------------------------------
const createEfs = app.node.tryGetContext('createEfs') === 'true';
if (createEfs) {
  new EfsPersistenceStack(app, `${stackName}-efs`, {
    env: {
      account: process.env.CDK_DEFAULT_ACCOUNT,
      region: process.env.CDK_DEFAULT_REGION,
    },
    project: project || undefined,
    purpose: purpose || undefined,
  });
}

new NeuronCodeServerStack(app, stackName, {
  env: {
    account: process.env.CDK_DEFAULT_ACCOUNT,
    region: process.env.CDK_DEFAULT_REGION,
  },
  instanceType,
  useCapacityBlock,
  capacityReservationId,
  useSpot,
  spotMaxPrice,
  spotInterruptionBehavior,
  subnetId,
  volumeSize,
  efsId,
  efsSubpath,
  installClaudeCode,
  project: project || undefined,
  purpose: purpose || undefined,
  forceRecreateToken: forceRecreateToken || undefined,
});

// ---------------------------------------------------------------------------
// Phase 3: Cognito UserPool + Hosted UI (opt-in via -c createCognito=true)
// ---------------------------------------------------------------------------
// UserPool + Hosted UI domain on *.amazoncognito.com. The UserPoolClient
// is created later in CloudFrontFrontendStack because its callback URL
// depends on the CloudFront distribution's default domain.
//
// Cognito is created BEFORE the ALB stack (ADR-011) because the OAuth
// Lambda lives in AlbBackendStack and needs to reference the UserPool +
// Hosted UI domain at synth time.
//
// Optional context:
//   -c cognitoDomainPrefix=<prefix>  (default: <stackName>-cognito-ops)
const createCognito = app.node.tryGetContext('createCognito') === 'true';
let cognitoStack: CognitoOperatorStack | undefined;
if (createCognito) {
  const domainPrefix = app.node.tryGetContext('cognitoDomainPrefix');
  // Optional one-shot operator bootstrap (ADR-013). The password is
  // never passed via context — only the Secrets Manager ARN — so it
  // does not land in cdk.out / CFN templates / drift detection.
  const operatorEmail = app.node.tryGetContext('operatorEmail');
  const operatorPasswordSecretArn = app.node.tryGetContext(
    'operatorPasswordSecretArn',
  );
  cognitoStack = new CognitoOperatorStack(app, `${stackName}-cognito`, {
    env: {
      account: process.env.CDK_DEFAULT_ACCOUNT,
      region: process.env.CDK_DEFAULT_REGION,
    },
    domainPrefix: domainPrefix || undefined,
    operatorEmail: operatorEmail || undefined,
    operatorPasswordSecretArn: operatorPasswordSecretArn || undefined,
    project: project || undefined,
    purpose: purpose || undefined,
  });
}

// ---------------------------------------------------------------------------
// Phase 2: ALB-Backend stack (opt-in via -c createAlbBackend=true)
// ---------------------------------------------------------------------------
//
// Deploys an INTERNAL ALB plus listener rules wired to the EC2 instance,
// AND owns the OAuth Lambda exposed via ALB Lambda Target Group (ADR-011):
//   - /oauth/*       [X-Origin-Verify] -> Lambda TG (OAuth Lambda)
//   - /api/llm/*     [X-Origin-Verify] -> :8090 (Qwen3 LLM)
//   - /api/vton/*    [X-Origin-Verify] -> :8081 (Qwen-Image-Edit)
//   - /api/whisper/* [X-Origin-Verify] -> :8765 (Whisper)
//   - /api/avatar/*  [X-Origin-Verify] -> :8770 (MuseTalk, future)
//   - default catch-all [X-Origin-Verify] -> :80 (code-server)
//
// SECURITY: the ALB SG has NO ingress at this stage. The CloudFront
// frontend stack (Phase 4) is the only caller that opens the inbound;
// it adds the CloudFront origin-facing managed prefix list. Until then
// the ALB is unreachable, which is the intended fail-closed behaviour.
//
// REQUIRES: createCognito=true in the SAME `cdk deploy` (the OAuth
// Lambda env consumes the UserPool id + Hosted UI FQDN at synth).
//
// Inputs come from the EC2 stack outputs and are passed via context:
//   -c albEc2InstanceId=<id> -c albEc2SecurityGroupId=<sg>
const createAlbBackend = app.node.tryGetContext('createAlbBackend') === 'true';
let albStack: AlbBackendStack | undefined;
if (createAlbBackend) {
  if (!cognitoStack) {
    throw new Error(
      'createAlbBackend=true requires createCognito=true in the same deploy ' +
        '(OAuth Lambda lives in the ALB stack and references the UserPool, ADR-011).'
    );
  }
  const albEc2InstanceId = app.node.tryGetContext('albEc2InstanceId');
  const albEc2SecurityGroupId = app.node.tryGetContext('albEc2SecurityGroupId');
  if (!albEc2InstanceId || !albEc2SecurityGroupId) {
    throw new Error(
      'createAlbBackend=true requires -c albEc2InstanceId=<id> and -c albEc2SecurityGroupId=<sg>. ' +
        'Pass the InstanceId and SecurityGroupId outputs from the EC2 stack.'
    );
  }
  albStack = new AlbBackendStack(app, `${stackName}-alb`, {
    env: {
      account: process.env.CDK_DEFAULT_ACCOUNT,
      region: process.env.CDK_DEFAULT_REGION,
    },
    ec2InstanceId: albEc2InstanceId,
    ec2SecurityGroupId: albEc2SecurityGroupId,
    userPool: cognitoStack.userPool,
    userPoolDomain: cognitoStack.userPoolDomain,
    project: project || undefined,
    purpose: purpose || undefined,
  });
}

// ---------------------------------------------------------------------------
// Phase 4: CloudFront frontend (opt-in via -c createCloudFrontFrontend=true)
// ---------------------------------------------------------------------------
// CloudFrontFrontendStack adds:
//   - CloudFront Function viewer-request (HMAC verify, ~0.05ms)
//     HMAC secret is owned by AlbBackendStack (where the OAuth Lambda
//     lives, ADR-011) and inlined here at synth time
//   - VPC Origin -> internal ALB :80 (single origin for default AND /oauth/*)
//   - UserPoolClient bound to dXXXX.cloudfront.net/oauth/callback
//   - ALB SG inbound: CloudFront origin-facing managed prefix list
//
// NOTE: per ADR-011, OAuth Lambda + Function URL are NO LONGER in this
// stack. The Lambda is reached via /oauth/* listener rule on the ALB.
//
// REQUIRES: createAlbBackend=true AND createCognito=true in the SAME
// `cdk deploy` (the stack consumes their L2 references directly).
const createCloudFrontFrontend =
  app.node.tryGetContext('createCloudFrontFrontend') === 'true';
if (createCloudFrontFrontend) {
  if (!albStack) {
    throw new Error(
      'createCloudFrontFrontend=true requires createAlbBackend=true in the same deploy.'
    );
  }
  if (!cognitoStack) {
    throw new Error(
      'createCloudFrontFrontend=true requires createCognito=true in the same deploy.'
    );
  }
  new CloudFrontFrontendStack(app, `${stackName}-frontend`, {
    env: {
      account: process.env.CDK_DEFAULT_ACCOUNT,
      region: process.env.CDK_DEFAULT_REGION,
    },
    userPool: cognitoStack.userPool,
    alb: albStack.alb,
    albSecurityGroupId: albStack.albSecurityGroup.securityGroupId,
    originVerifySecret: albStack.originVerifySecret,
    hmacSecret: albStack.hmacSecret,
    project: project || undefined,
    purpose: purpose || undefined,
  });
}
