import * as cdk from 'aws-cdk-lib';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as elbtg from 'aws-cdk-lib/aws-elasticloadbalancingv2-targets';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

/**
 * neuron-anatomy ALB ListenerRule + TargetGroup.
 *
 * Sits alongside voice-image-edit's {api,stream,frontend}-stack and does
 * not touch any of them. The default priority slot is 250 (between the
 * frontend rule at 200 and the code-server catch-all at 1000), so adding
 * /neuron/* never collides with existing rules. Listener rule conditions
 * mirror the other app stacks: path pattern + the X-Origin-Verify header
 * inlined from Secrets Manager at synth time.
 *
 * Required context:
 *   - albArn                       : base ALB ARN
 *   - albListenerArn               : base listener ARN
 *   - albListenerSgId              : ListenerRule.fromAttributes wants the SG id
 *   - albSecurityGroupId           : source SG for the EC2 ingress rule we add
 *   - originVerifyHeaderName       : e.g. X-Origin-Verify
 *   - originVerifySecretArn        : Secrets Manager (inlined at synth time)
 *   - anatomyInstancePrivateIp     : EC2 private IPv4
 *   - anatomyInstanceSgId          : EC2 SG to add ingress to
 *   - anatomyVpcId                 : VPC the target group lives in
 *
 * Optional context:
 *   - anatomyPort                  : default 8810
 *   - anatomyPathPattern           : default /neuron/*
 *   - anatomyRulePriority          : default 250
 */
export interface NeuronAnatomyStackProps extends cdk.StackProps {}

export class NeuronAnatomyStack extends cdk.Stack {
  constructor(scope: Construct, id: string, props: NeuronAnatomyStackProps) {
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
    const anatomyInstancePrivateIp = ctxRequired('anatomyInstancePrivateIp');
    const anatomyInstanceSgId = ctxRequired('anatomyInstanceSgId');
    const anatomyVpcId = ctxRequired('anatomyVpcId');

    const port = Number(ctx('anatomyPort') ?? '8810');
    const pathPattern = ctx('anatomyPathPattern') ?? '/neuron/*';
    const priority = Number(ctx('anatomyRulePriority') ?? '250');

    const vpc = ec2.Vpc.fromLookup(this, 'BaseVpc', { vpcId: anatomyVpcId });

    const albSg = ec2.SecurityGroup.fromSecurityGroupId(
      this,
      'AlbSg',
      albSecurityGroupId,
      { mutable: false },
    );

    const ec2Sg = ec2.SecurityGroup.fromSecurityGroupId(
      this,
      'Ec2Sg',
      anatomyInstanceSgId,
      { mutable: true },
    );
    ec2Sg.addIngressRule(
      albSg,
      ec2.Port.tcp(port),
      `ALB to neuron-anatomy port ${port}`,
    );

    const targetGroup = new elbv2.ApplicationTargetGroup(this, 'NeuronAnatomyTg', {
      vpc,
      port,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.IP,
      targets: [new elbtg.IpTarget(anatomyInstancePrivateIp, port)],
      healthCheck: {
        // The backend exposes a bare /health (no /neuron prefix) so the
        // health check stays cheap.
        path: '/health',
        healthyHttpCodes: '200',
        interval: cdk.Duration.seconds(30),
        timeout: cdk.Duration.seconds(10),
        unhealthyThresholdCount: 5,
      },
      // Keep deregistration short so SSE long connections do not block drains.
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

    new elbv2.ApplicationListenerRule(this, 'NeuronAnatomyRule', {
      listener,
      priority,
      conditions: [
        elbv2.ListenerCondition.pathPatterns([pathPattern]),
        elbv2.ListenerCondition.httpHeader(originHeader, [originVerifyValue]),
      ],
      action: elbv2.ListenerAction.forward([targetGroup]),
    });

    new cdk.CfnOutput(this, 'NeuronAnatomyTargetGroupArn', { value: targetGroup.targetGroupArn });
    new cdk.CfnOutput(this, 'NeuronAnatomyInstancePrivateIp', { value: anatomyInstancePrivateIp });
    new cdk.CfnOutput(this, 'NeuronAnatomyPort', { value: String(port) });
    new cdk.CfnOutput(this, 'NeuronAnatomyPathPattern', { value: pathPattern });
    new cdk.CfnOutput(this, 'NeuronAnatomyRulePriority', { value: String(priority) });
    new cdk.CfnOutput(this, 'NeuronAnatomyAlbArn', { value: albArn });
  }
}
