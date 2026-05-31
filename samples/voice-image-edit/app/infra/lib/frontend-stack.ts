import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as elbtg from 'aws-cdk-lib/aws-elasticloadbalancingv2-targets';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

/**
 * voice-image-edit Stage 2 / フロントエンド配信レイヤ。
 *
 * Stage 1 (setup/single-node) で立てた既存 EC2 上で Next.js standalone server
 * (port 3000) を systemd で常駐させる前提。本 Stack はインフラ側のルーティング:
 *
 *   - EC2 SG に「ALB SG -> 3000/tcp」の ingress を 1 本追加
 *   - 既存 ALB に Frontend Target Group (instance target, port 3000) を作成
 *   - X-Origin-Verify header 一致を要求する path-based ListenerRule を生やす
 *     Default patterns are ['/edit*', '/manage*', '/_next/*'].
 *     '/' is intentionally NOT matched here so it falls through to the
 *     code-server catch-all (priority 1000); users enter the
 *     voice-image-edit UI at /edit.  This avoids fighting other apps
 *     (code-server, Neuron Explorer) that share the same ALB for '/'.
 *     ALB は 1 rule 全 condition 合計で最大 5 値 (path + header)。
 *     header 1 値を確保するため path は 4 値以下に抑える。
 *     priority 200 (code-server catch-all 1000 より強く、api rule 100 より弱い)
 *
 * 必須 context:
 *   - albArn                       : 基盤 ALB ARN
 *   - albListenerArn               : 基盤 listener (HTTP :80) ARN
 *   - albListenerSgId              : ListenerRule import 用 (CDK 必須引数)
 *   - albSecurityGroupId           : EC2 SG に ingress を生やすときの src
 *   - originVerifyHeaderName       : 例 X-Origin-Verify
 *   - originVerifySecretArn        : Secrets Manager (synth-time inline)
 *   - frontendInstanceId           : Next.js を起動する EC2 instance id
 *   - frontendVpcId                : Target Group が属する VPC id (基盤 default VPC)
 *   - frontendInstanceSgId         : EC2 instance の SG (3000 ingress を生やす対象)
 *
 * 任意 context:
 *   - frontendPort                 : default = 3000
 *   - frontendPathPatterns         : カンマ区切り。default は上記 7 パターン
 *   - frontendRulePriority         : default = 200
 */
export interface FrontendStackProps extends cdk.StackProps {}

export class FrontendStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: FrontendStackProps) {
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
    const frontendInstanceId = ctxRequired('frontendInstanceId');
    const frontendVpcId = ctxRequired('frontendVpcId');
    const frontendInstanceSgId = ctxRequired('frontendInstanceSgId');

    const frontendPort = Number(ctx('frontendPort') ?? '3000');
    // ALB は 1 rule 全 condition 合計で最大 5 値 (path + header)。
    // header 1 を確保するため path は 4 値以下に抑える必要がある。
    // '/edit*' / '/manage*' は末尾 wildcard で完全一致も prefix もカバー。
    // '/' is intentionally omitted: it falls through to the code-server
    // catch-all (priority 1000) so other apps sharing the ALB
    // (code-server, Neuron Explorer) keep '/' for themselves.  Users
    // enter the voice-image-edit UI at /edit.
    const frontendPathPatterns = (
      ctx('frontendPathPatterns') ??
      '/edit*,/manage*,/_next/*'
    )
      .split(',')
      .map((s) => s.trim())
      .filter(Boolean);
    if (frontendPathPatterns.length > 4) {
      throw new Error(
        `frontendPathPatterns must be <= 4 entries (ALB rule limit; header consumes 1 of 5); got ${frontendPathPatterns.length}`,
      );
    }
    const frontendRulePriority = Number(ctx('frontendRulePriority') ?? '200');

    // ---- VPC + SG imports ----
    // VPC は instanceVpcId 指定だけで十分 (TG が VPC を要求するため)。
    const vpc = ec2.Vpc.fromLookup(this, 'BaseVpc', { vpcId: frontendVpcId });

    // ALB SG: EC2 SG に ingress を引く際のソース。mutable: false で参照のみ。
    const albSg = ec2.SecurityGroup.fromSecurityGroupId(
      this,
      'AlbSg',
      albSecurityGroupId,
      { mutable: false },
    );

    // EC2 instance SG: 3000/tcp の ingress を ALB SG から開ける。mutable: true。
    const ec2Sg = ec2.SecurityGroup.fromSecurityGroupId(
      this,
      'Ec2Sg',
      frontendInstanceSgId,
      { mutable: true },
    );
    // SG rule description は EC2 が許可する charset が限定的 (矢印などは不可)。
    // a-zA-Z0-9 と一部記号のみ受け付けるので ASCII のみで書く。
    ec2Sg.addIngressRule(
      albSg,
      ec2.Port.tcp(frontendPort),
      `ALB to Next.js frontend port ${frontendPort}`,
    );

    // ---- Frontend Target Group (instance target) ----
    const targetGroup = new elbv2.ApplicationTargetGroup(this, 'FrontendTg', {
      vpc,
      port: frontendPort,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.INSTANCE,
      targets: [new elbtg.InstanceIdTarget(frontendInstanceId, frontendPort)],
      healthCheck: {
        // Next.js standalone は / が常に 200 を返すので最小限の health check で十分。
        path: '/',
        // Next.js は SSR 中に 307 (redirect) を返すケースもあるため許容。
        healthyHttpCodes: '200,302,307,404',
        interval: cdk.Duration.seconds(30),
        timeout: cdk.Duration.seconds(10),
        unhealthyThresholdCount: 5,
      },
    });

    // ---- Listener import (header secret value inline) ----
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

    // 既存 alb-backend-stack と同じく、CloudFront が注入する X-Origin-Verify の
    // 実値を synth-time に Secrets Manager から取り出して inline する。
    const originVerifySecret = secretsmanager.Secret.fromSecretCompleteArn(
      this,
      'OriginVerifySecret',
      originVerifySecretArn,
    );
    const originVerifyValue = originVerifySecret.secretValue.unsafeUnwrap();

    new elbv2.ApplicationListenerRule(this, 'FrontendRule', {
      listener,
      priority: frontendRulePriority,
      conditions: [
        elbv2.ListenerCondition.pathPatterns(frontendPathPatterns),
        elbv2.ListenerCondition.httpHeader(originHeader, [originVerifyValue]),
      ],
      action: elbv2.ListenerAction.forward([targetGroup]),
    });

    new cdk.CfnOutput(this, 'FrontendTargetGroupArn', { value: targetGroup.targetGroupArn });
    new cdk.CfnOutput(this, 'FrontendInstanceId', { value: frontendInstanceId });
    new cdk.CfnOutput(this, 'FrontendPort', { value: String(frontendPort) });
    new cdk.CfnOutput(this, 'FrontendRulePriority', { value: String(frontendRulePriority) });
    new cdk.CfnOutput(this, 'FrontendPathPatterns', { value: frontendPathPatterns.join(',') });
    new cdk.CfnOutput(this, 'FrontendAlbArn', { value: albArn });
  }
}
