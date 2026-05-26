import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as elbtg from 'aws-cdk-lib/aws-elasticloadbalancingv2-targets';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

/**
 * voice-image-edit Stage 2 / streaming レイヤ (P8 skeleton)。
 *
 * 既存 EC2 上の uvicorn (port 8800) を IP target で受ける Target Group を
 * 立て、X-Origin-Verify header 一致の path-based Listener Rule を生やす。
 * SSE / WebSocket の取り回しが ALB 経由で問題なく動くかを最小コストで
 * 確認するためのインフラ枠であり、本番 SSE ロジックは P9 で別途乗せる。
 *
 * 設計メモ:
 *   - target type: instance ではなく ip にする。理由は将来 SSE backend を
 *     ECS / EC2 を行き来させても TG を作り替えずに済むこと、および
 *     EC2 instance metadata に依存しない (frontend と同居 EC2 ではあるが
 *     TG 上は別物として扱う) こと。
 *   - VPC は frontend-stack と同じく default VPC 想定。Vpc.fromLookup で引く。
 *   - Listener rule priority は Frontend (200) と code-server catch-all
 *     (1000) の間で、api (100) より低い 150 を default。
 *   - ALB SG -> EC2 SG (port 8800) の ingress も同じ stack で生やす。
 *     mutable: true で frontend-stack が立てた既存 SG に追記する。
 *
 * 必須 context:
 *   - albArn                       : 基盤 ALB ARN
 *   - albListenerArn               : 基盤 listener (HTTP :80) ARN
 *   - albListenerSgId              : ListenerRule import 用 (CDK 必須引数)
 *   - albSecurityGroupId           : EC2 SG に ingress を生やすときの src
 *   - originVerifyHeaderName       : 例 X-Origin-Verify
 *   - originVerifySecretArn        : Secrets Manager (synth-time inline)
 *   - streamInstancePrivateIp      : SSE 受け EC2 の private IPv4
 *   - streamInstanceSgId           : SSE 受け EC2 の SG (8080 ingress を生やす対象)
 *   - streamVpcId                  : Target Group が属する VPC
 *
 * 任意 context:
 *   - streamPort                   : default = 8080
 *   - streamPathPattern            : default = /stream/*
 *   - streamRulePriority           : default = 150
 */
export interface StreamStackProps extends cdk.StackProps {}

export class StreamStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: StreamStackProps) {
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
    const streamInstancePrivateIp = ctxRequired('streamInstancePrivateIp');
    const streamInstanceSgId = ctxRequired('streamInstanceSgId');
    const streamVpcId = ctxRequired('streamVpcId');

    const streamPort = Number(ctx('streamPort') ?? '8800');
    const streamPathPattern = ctx('streamPathPattern') ?? '/stream/*';
    const streamRulePriority = Number(ctx('streamRulePriority') ?? '150');

    const vpc = ec2.Vpc.fromLookup(this, 'BaseVpc', { vpcId: streamVpcId });

    const albSg = ec2.SecurityGroup.fromSecurityGroupId(
      this,
      'AlbSg',
      albSecurityGroupId,
      { mutable: false },
    );

    // EC2 SG に ALB SG -> 8080/tcp の ingress を 1 本追加。
    // SG description は ASCII のみ (frontend-stack と同じ制限)。
    const ec2Sg = ec2.SecurityGroup.fromSecurityGroupId(
      this,
      'Ec2Sg',
      streamInstanceSgId,
      { mutable: true },
    );
    ec2Sg.addIngressRule(
      albSg,
      ec2.Port.tcp(streamPort),
      `ALB to voice-image-edit-stream port ${streamPort}`,
    );

    // IP target Target Group。SSE / WS は health check が単純な GET でも
    // 拾えるので /stream/health (200 JSON) を見る。
    // SSE 中の long connection が deregistration_delay を握るのを避けるため
    // deregistration_delay を 30s に下げる (default 300s)。
    const targetGroup = new elbv2.ApplicationTargetGroup(this, 'StreamTg', {
      vpc,
      port: streamPort,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.IP,
      targets: [new elbtg.IpTarget(streamInstancePrivateIp, streamPort)],
      healthCheck: {
        path: '/stream/health',
        healthyHttpCodes: '200',
        interval: cdk.Duration.seconds(30),
        timeout: cdk.Duration.seconds(10),
        unhealthyThresholdCount: 5,
      },
      deregistrationDelay: cdk.Duration.seconds(30),
    });

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

    new elbv2.ApplicationListenerRule(this, 'StreamRule', {
      listener,
      priority: streamRulePriority,
      conditions: [
        elbv2.ListenerCondition.pathPatterns([streamPathPattern]),
        elbv2.ListenerCondition.httpHeader(originHeader, [originVerifyValue]),
      ],
      action: elbv2.ListenerAction.forward([targetGroup]),
    });

    new cdk.CfnOutput(this, 'StreamTargetGroupArn', { value: targetGroup.targetGroupArn });
    new cdk.CfnOutput(this, 'StreamInstancePrivateIp', { value: streamInstancePrivateIp });
    new cdk.CfnOutput(this, 'StreamPort', { value: String(streamPort) });
    new cdk.CfnOutput(this, 'StreamPathPattern', { value: streamPathPattern });
    new cdk.CfnOutput(this, 'StreamRulePriority', { value: String(streamRulePriority) });
    new cdk.CfnOutput(this, 'StreamAlbArn', { value: albArn });
  }
}
