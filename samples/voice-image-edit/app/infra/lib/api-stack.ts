import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as elbtg from 'aws-cdk-lib/aws-elasticloadbalancingv2-targets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as s3 from 'aws-cdk-lib/aws-s3';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

/**
 * voice-image-edit /api/edit/* を担う FastAPI/uvicorn を EC2 上に居候させる
 * ALB ルーティング + S3 + IAM スタック (P10 で Lambda 退役後の置き換え)。
 *
 * 既存 EC2 上の uvicorn (port 8801) を IP target で受ける Target Group を立て、
 * X-Origin-Verify header 一致の path-based Listener Rule (priority 100) を生やす。
 * EDIT 結果を inline base64 で返すと SSE 経路で巨大化するため、Nova Canvas 出力 PNG
 * は S3 (短命 bucket、1 日 expire) に put して presigned URL で返す方式を維持する
 * (P9-D-3 で導入、P10 で恒久化を確認)。
 *
 * 設計メモ:
 *   - target type: instance ではなく ip にする (stream-stack と同方針)。
 *   - VPC は frontend-stack と同じく default VPC 想定。
 *   - Listener rule priority は 100 (旧 EditApiStack と同じ値)。
 *   - ALB SG -> EC2 SG (port 8801) の ingress を mutable: true で生やす。
 *   - EC2 instance role (Stage 1 で managed) に bedrock:*, transcribe:*, s3:* を addToPrincipalPolicy。
 *
 * 必須 context:
 *   - albArn                       : 基盤 ALB ARN
 *   - albListenerArn               : 基盤 listener (HTTP :80) ARN
 *   - albListenerSgId              : ListenerRule import 用 (CDK 必須引数)
 *   - albSecurityGroupId           : EC2 SG に ingress を生やすときの src
 *   - originVerifyHeaderName       : 例 X-Origin-Verify
 *   - originVerifySecretArn        : Secrets Manager (synth-time inline)
 *   - apiInstancePrivateIp         : API backend を載せた EC2 の private IPv4
 *   - apiInstanceSgId              : 同 EC2 の SG (8801 ingress を生やす対象)
 *   - apiInstanceRoleName          : 同 EC2 の IAM Role 名 (bedrock / transcribe / s3 attach 先)
 *   - apiVpcId                     : Target Group が属する VPC
 *   - bedrockRegion                : 例 us-east-1 (IAM resource ARN の region に使う)
 *
 * 任意 context:
 *   - apiPort                      : default = 8801
 *   - apiPathPattern               : default = /api/edit/*
 *   - apiRulePriority              : default = 100
 *   - generateBedrockRegion        : default = us-west-2 (Stability text-to-image)
 *   - editBedrockRegion            : default = us-west-2 (Stability image-to-image)
 */
export interface ApiStackProps extends cdk.StackProps {}

export class ApiStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: ApiStackProps) {
    super(scope, id, props);

    const ctx = (key: string): string | undefined =>
      this.node.tryGetContext(key) as string | undefined;
    const ctxRequired = (key: string): string => {
      const v = ctx(key);
      if (!v) {
        throw new Error(`context '${key}' is required (pass with -c ${key}=...)`);
      }
      return v;
    };

    const albArn = ctxRequired('albArn');
    const albListenerArn = ctxRequired('albListenerArn');
    const albListenerSgId = ctxRequired('albListenerSgId');
    const albSecurityGroupId = ctxRequired('albSecurityGroupId');
    const originHeader = ctxRequired('originVerifyHeaderName');
    const originVerifySecretArn = ctxRequired('originVerifySecretArn');
    const apiInstancePrivateIp = ctxRequired('apiInstancePrivateIp');
    const apiInstanceSgId = ctxRequired('apiInstanceSgId');
    const apiInstanceRoleName = ctxRequired('apiInstanceRoleName');
    const apiVpcId = ctxRequired('apiVpcId');
    const bedrockRegion = ctxRequired('bedrockRegion');

    const apiPort = Number(ctx('apiPort') ?? '8801');
    const apiPathPattern = ctx('apiPathPattern') ?? '/api/edit/*';
    const apiRulePriority = Number(ctx('apiRulePriority') ?? '100');

    // Stability AI 系モデル (`stability.stable-image-*` / `stability.sd3-5-*`)
    // は us-west-2 のみで提供されているため、Generate (text-to-image) と Edit
    // (image-to-image) のどちらも `bedrockRegion` (Nova / Claude 用、通常は
    // us-east-1) では呼び出せない。IAM resource ARN と runtime env の両方に
    // 流すため、Generate と Edit を独立した ctx で持つ (将来 Edit を別モデル
    // で別リージョンに動かせるようにする)。両方未指定なら us-west-2 で動く。
    const generateBedrockRegion = ctx('generateBedrockRegion') ?? 'us-west-2';
    const editBedrockRegion = ctx('editBedrockRegion') ?? 'us-west-2';
    const bedrockResourceRegions = Array.from(
      new Set([bedrockRegion, generateBedrockRegion, editBedrockRegion]),
    );

    const vpc = ec2.Vpc.fromLookup(this, 'BaseVpc', { vpcId: apiVpcId });

    // ---- S3: EDIT 結果保存 bucket (presigned URL で frontend に返す) ----
    // 旧 EditApiStack の EditResultBucket と同じ運用 (1 日 expire, CORS)。
    // CloudFront / ALB / Cognito 構成は触らず、Browser は presigned URL を直接 fetch する。
    const editResultBucket = new s3.Bucket(this, 'EditResultBucket', {
      blockPublicAccess: s3.BlockPublicAccess.BLOCK_ALL,
      encryption: s3.BucketEncryption.S3_MANAGED,
      enforceSSL: true,
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      autoDeleteObjects: true,
      lifecycleRules: [
        {
          expiration: cdk.Duration.days(1),
          abortIncompleteMultipartUploadAfter: cdk.Duration.days(1),
        },
      ],
      cors: [
        {
          allowedMethods: [s3.HttpMethods.GET, s3.HttpMethods.HEAD],
          allowedOrigins: ['*'],
          allowedHeaders: ['*'],
          exposedHeaders: ['ETag', 'Content-Length', 'Content-Type'],
          maxAge: 300,
        },
      ],
    });

    // ---- IAM: EC2 instance role に Bedrock / Transcribe / S3 を attach ----
    // Stage 1 (torch-neuron-stack.ts) が Stage 1 deploy で作る CodeServerInstanceRole に
    // 後付けで policy を生やす形にして、Stage 1 のスタック差分を出さないようにする。
    const apiInstanceRole = iam.Role.fromRoleName(this, 'ApiInstanceRole', apiInstanceRoleName);

    apiInstanceRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        sid: 'BedrockInvokeForEditApi',
        actions: [
          'bedrock:InvokeModel',
          'bedrock:Converse',
          'bedrock:ConverseStream',
          'bedrock:InvokeModelWithResponseStream',
        ],
        // Allow every region the API needs: bedrockRegion (Claude / Nova),
        // generateBedrockRegion (Stability text-to-image),
        // editBedrockRegion (Stability image-to-image).
        resources: bedrockResourceRegions.map(
          (r) => `arn:aws:bedrock:${r}::foundation-model/*`,
        ),
      }),
    );
    apiInstanceRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        sid: 'TranscribeStreamingForEditApi',
        // StartStreamTranscription はリソース ARN を取らないため '*'。
        actions: ['transcribe:StartStreamTranscription'],
        resources: ['*'],
      }),
    );
    // Amazon Polly is the cloud TTS provider for the optional review-readout
    // stage (engine: bedrock_polly_*). SynthesizeSpeech does not take a
    // resource ARN — '*' is the documented form. We grant the action in
    // every region the CDK app may run in so the stack stays portable.
    apiInstanceRole.addToPrincipalPolicy(
      new iam.PolicyStatement({
        sid: 'PollySynthesizeForEditApi',
        actions: ['polly:SynthesizeSpeech', 'polly:DescribeVoices'],
        resources: ['*'],
      }),
    );
    editResultBucket.grantPut(apiInstanceRole);
    editResultBucket.grantRead(apiInstanceRole);

    // ---- SG: ALB SG -> EC2 SG (8801) の ingress を 1 本 ----
    const albSg = ec2.SecurityGroup.fromSecurityGroupId(
      this,
      'AlbSg',
      albSecurityGroupId,
      { mutable: false },
    );
    const ec2Sg = ec2.SecurityGroup.fromSecurityGroupId(
      this,
      'Ec2Sg',
      apiInstanceSgId,
      { mutable: true },
    );
    ec2Sg.addIngressRule(
      albSg,
      ec2.Port.tcp(apiPort),
      `ALB to voice-image-edit-api port ${apiPort}`,
    );

    // ---- Target Group (IP target) ----
    // health check は /api/edit/health (200 JSON)。deregistration_delay は短く。
    const targetGroup = new elbv2.ApplicationTargetGroup(this, 'ApiTg', {
      vpc,
      port: apiPort,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.IP,
      targets: [new elbtg.IpTarget(apiInstancePrivateIp, apiPort)],
      healthCheck: {
        path: '/api/edit/health',
        healthyHttpCodes: '200',
        interval: cdk.Duration.seconds(30),
        timeout: cdk.Duration.seconds(10),
        unhealthyThresholdCount: 5,
      },
      deregistrationDelay: cdk.Duration.seconds(30),
    });

    // ---- Listener rule import (header secret value inline) ----
    const albListenerSg = ec2.SecurityGroup.fromSecurityGroupId(
      this,
      'AlbListenerSg',
      albListenerSgId,
      { mutable: false },
    );
    const listener = elbv2.ApplicationListener.fromApplicationListenerAttributes(
      this,
      'AlbListener',
      {
        listenerArn: albListenerArn,
        securityGroup: albListenerSg,
      },
    );

    const originVerifySecret = secretsmanager.Secret.fromSecretCompleteArn(
      this,
      'OriginVerifySecret',
      originVerifySecretArn,
    );
    const originVerifyValue = originVerifySecret.secretValue.unsafeUnwrap();

    new elbv2.ApplicationListenerRule(this, 'ApiRule', {
      listener,
      priority: apiRulePriority,
      conditions: [
        elbv2.ListenerCondition.pathPatterns([apiPathPattern]),
        elbv2.ListenerCondition.httpHeader(originHeader, [originVerifyValue]),
      ],
      action: elbv2.ListenerAction.forward([targetGroup]),
    });

    new cdk.CfnOutput(this, 'ApiTargetGroupArn', { value: targetGroup.targetGroupArn });
    new cdk.CfnOutput(this, 'ApiInstancePrivateIp', { value: apiInstancePrivateIp });
    new cdk.CfnOutput(this, 'ApiPort', { value: String(apiPort) });
    new cdk.CfnOutput(this, 'ApiPathPattern', { value: apiPathPattern });
    new cdk.CfnOutput(this, 'ApiRulePriority', { value: String(apiRulePriority) });
    new cdk.CfnOutput(this, 'ApiAlbArn', { value: albArn });
    new cdk.CfnOutput(this, 'ApiResultBucketName', { value: editResultBucket.bucketName });
    new cdk.CfnOutput(this, 'ApiInstanceRoleName', { value: apiInstanceRoleName });
    new cdk.CfnOutput(this, 'ApiOriginVerifySecretArn', { value: originVerifySecretArn });
  }
}
