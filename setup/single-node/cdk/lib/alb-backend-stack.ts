import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as elbv2Targets from 'aws-cdk-lib/aws-elasticloadbalancingv2-targets';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

/**
 * Per-app routing entry. Tells the stack to create a TG for `port` and
 * forward `pathPattern` (e.g. `/api/llm/*`) to it when the secret header
 * is present. The same EC2 instance is registered into every TG so a
 * single host can serve multiple containers on different ports.
 */
export interface AlbAppRoute {
  /** Human readable name; used in TG / rule logical IDs. */
  readonly name: string;
  /** ALB listener rule path pattern. Must end with `/*` for prefix match. */
  readonly pathPattern: string;
  /** Backend container port the TG forwards to. */
  readonly port: number;
  /**
   * Health check path on the backend container. Accepted codes are
   * permissive (200/302/401/404) so health-check does not flap while a
   * container is still warming up.
   */
  readonly healthCheckPath?: string;
}

export interface AlbBackendStackProps extends cdk.StackProps {
  /**
   * EC2 instance id of the code-server / app host. The same instance is
   * registered into every target group on different ports.
   */
  readonly ec2InstanceId: string;
  /**
   * Security group attached to the EC2 instance. Imported with
   * mutable: true so we can add ingress rules from the ALB SG only.
   */
  readonly ec2SecurityGroupId: string;
  /**
   * Cognito UserPool consumed by the OAuth Lambda. Required for
   * ListUserPoolClients / DescribeUserPoolClient permissions and the
   * COGNITO_USER_POOL_ID env var.
   */
  readonly userPool: cognito.IUserPool;
  /**
   * Cognito Hosted UI domain (the prefix part). The OAuth Lambda
   * builds the Hosted UI FQDN at synth time for redirects to
   * /oauth2/authorize and /oauth2/token.
   */
  readonly userPoolDomain: cognito.IUserPoolDomain;
  /**
   * Port the code-server / nginx fronting it listens on. Default 80.
   * Receives the listener default action (no path match).
   */
  readonly codeServerPort?: number;
  /**
   * Application path-based routes. Default ones already cover the four
   * StoreAI services (LLM / VTON / Whisper / Avatar).
   */
  readonly appRoutes?: AlbAppRoute[];
  /** Project / purpose tags. */
  readonly project?: string;
  readonly purpose?: string;
}

/**
 * Internal ALB + OAuth Lambda + 5 target groups (1 default + N apps)
 * wired to a single EC2 instance host running multiple containers on
 * different ports.
 *
 * SECURITY MODEL — relevant invariants
 *   - ALB scheme = INTERNAL (no public IP / DNS)
 *   - Listener `open: false` so CDK does not auto-add 0.0.0.0/0 ingress
 *   - ALB SG inbound is empty at creation. The CloudFront frontend
 *     stack (per ADR-005 + ADR-011) is the only caller that opens it;
 *     it adds the CloudFront origin-facing managed prefix list to the
 *     ALB SG. **This stack does not open ingress to anyone.** The ALB
 *     is unreachable until the frontend stack lands.
 *   - EC2 SG receives a single ingress rule per app port (and the
 *     code-server port) sourced from the ALB SG. No 0.0.0.0/0.
 *   - Listener default action = 403 (fail-closed). The X-Origin-Verify
 *     header check on every rule is the second gate — even if the
 *     header is forwarded by mistake to /api/* paths, only requests
 *     carrying the matching value reach a backend TG.
 *
 * OAUTH LAMBDA (ADR-011)
 *   The OAuth Lambda lives in this stack and is exposed via an ALB
 *   Lambda Target Group, NOT via Function URL or API Gateway. This
 *   choice is structural: ALB Lambda Target has zero internet-resolvable
 *   hostname, so DAST UnauthWebEndpoint cannot detect it. Listener rule
 *   priority 1 catches `/oauth/*` (with X-Origin-Verify) and forwards
 *   to the Lambda TG. App rules start at priority 10 to leave slack.
 *
 * MULTI-CONTAINER ROUTING
 *   The same instance appears in every TG (code-server :80, LLM :8090,
 *   VTON :8081, Whisper :8765, Avatar :8770 by default). Each TG points
 *   at a different listening port on the same host. Operators register
 *   containers via docker compose; ALB health checks pick them up once
 *   they bind their port.
 */
export class AlbBackendStack extends cdk.Stack {
  /** Internal ALB. The CloudFront frontend stack consumes `loadBalancerArn` and SG. */
  public readonly alb: elbv2.ApplicationLoadBalancer;
  /** ALB SG. The CloudFront frontend stack adds an inbound rule for the CloudFront origin-facing prefix list. */
  public readonly albSecurityGroup: ec2.SecurityGroup;
  /** Listener for follow-up modules. */
  public readonly listener: elbv2.ApplicationListener;
  /**
   * Shared header value injected by CloudFront and required by
   * every listener rule. Stored in Secrets Manager so it can be rotated
   * by updating the secret + redeploying CloudFront's custom-headers config.
   */
  public readonly originVerifySecret: secretsmanager.Secret;
  /**
   * HMAC-SHA256 key used by both the OAuth Lambda (cookie issuance,
   * env var) and the CloudFront Function (cookie verify, inlined at
   * frontend-stack synth time). Owned here because the OAuth Lambda
   * lives here per ADR-011; the frontend stack reads it at synth.
   */
  public readonly hmacSecret: secretsmanager.Secret;
  /** OAuth Lambda function (ALB Lambda Target). */
  public readonly oauthLambda: lambda.Function;

  constructor(scope: Construct, id: string, props: AlbBackendStackProps) {
    super(scope, id, props);

    const codeServerPort = props.codeServerPort ?? 80;
    const appRoutes: AlbAppRoute[] = props.appRoutes ?? [
      { name: 'llm',     pathPattern: '/api/llm/*',     port: 8090, healthCheckPath: '/health' },
      { name: 'vton',    pathPattern: '/api/vton/*',    port: 8081, healthCheckPath: '/health' },
      { name: 'whisper', pathPattern: '/api/whisper/*', port: 8765, healthCheckPath: '/health' },
      { name: 'avatar',  pathPattern: '/api/avatar/*',  port: 8770, healthCheckPath: '/health' },
    ];

    const vpc = ec2.Vpc.fromLookup(this, 'DefaultVpc', { isDefault: true });

    // ---- Origin verification secret (CloudFront -> ALB) ----
    this.originVerifySecret = new secretsmanager.Secret(this, 'OriginVerifySecret', {
      description: 'CloudFront -> ALB shared secret for X-Origin-Verify header',
      generateSecretString: { excludePunctuation: true, passwordLength: 48 },
    });
    const originVerifyValue = this.originVerifySecret.secretValue.unsafeUnwrap();

    // ---- HMAC session secret (Lambda env + CF Function inline) ----
    // Generated once and consumed by:
    //   - OAuth Lambda (this stack) via env var to sign cf_session
    //   - CloudFront Function (frontend stack) inlined at synth to verify
    // Rotation = update this secret then redeploy BOTH stacks.
    this.hmacSecret = new secretsmanager.Secret(this, 'HmacSessionSecret', {
      description: 'HMAC-SHA256 key for cf_session opaque cookie (shared with CF Function)',
      generateSecretString: {
        excludePunctuation: true,
        passwordLength: 64,
      },
    });

    // ---- ALB + SG (zero ingress) ----
    this.albSecurityGroup = new ec2.SecurityGroup(this, 'AlbSg', {
      vpc,
      // The literal description is kept stable across ADR rewordings
      // because CloudFormation replaces SecurityGroup on description
      // edits, which would cascade-replace the ALB and target groups.
      // Document semantics here in code; the resource description just
      // needs to be deterministic.
      description:
        'Internal ALB SG. Inbound is added by CloudFrontFrontendStack (CloudFront origin-facing prefix list); this stack opens nothing.',
      allowAllOutbound: true,
    });

    this.alb = new elbv2.ApplicationLoadBalancer(this, 'Alb', {
      vpc,
      internetFacing: false, // INTERNAL: no public DNS, no public IP
      securityGroup: this.albSecurityGroup,
      // Drop invalid HTTP headers so a malformed client cannot smuggle
      // X-Origin-Verify into a request that also bypasses CloudFront.
      dropInvalidHeaderFields: true,
    });

    // ---- EC2 SG: open one port per route from the ALB SG only ----
    const ec2Sg = ec2.SecurityGroup.fromSecurityGroupId(
      this,
      'Ec2Sg',
      props.ec2SecurityGroupId,
      { mutable: true },
    );

    // code-server
    ec2Sg.addIngressRule(
      this.albSecurityGroup,
      ec2.Port.tcp(codeServerPort),
      `ALB to code-server (port ${codeServerPort})`,
    );
    // each app port
    for (const route of appRoutes) {
      ec2Sg.addIngressRule(
        this.albSecurityGroup,
        ec2.Port.tcp(route.port),
        `ALB to ${route.name} (port ${route.port})`,
      );
    }

    // ---- Listener: HTTP :80, default 403 (fail-closed), open: false ----
    // No HTTPS cert: the ALB is internal-only and reached via CloudFront
    // VPC Origin (TLS-terminated by CloudFront). Adding a cert would
    // force a per-region domain we don't need (ADR-001).
    this.listener = this.alb.addListener('Listener', {
      port: 80,
      protocol: elbv2.ApplicationProtocol.HTTP,
      defaultAction: elbv2.ListenerAction.fixedResponse(403, {
        contentType: 'text/plain',
        messageBody: 'Forbidden',
      }),
      open: false, // Critical: never let CDK auto-add 0.0.0.0/0 to the ALB SG.
    });

    // ---- OAuth Lambda (ADR-011) ----
    // The Lambda is exposed via an ALB Lambda Target Group below; it has
    // NO Function URL and NO API Gateway. The COGNITO_DOMAIN FQDN can be
    // built at synth time because it does not depend on the distribution.
    // CLOUDFRONT_DOMAIN and COGNITO_CLIENT_ID are deliberately resolved
    // at request time (Host header / ListUserPoolClients) to break the
    // CFN dep cycle: Distribution -> ALB stack -> Distribution.
    const cognitoDomainFqdn =
      `${props.userPoolDomain.domainName}.auth.${this.region}.amazoncognito.com`;
    this.oauthLambda = new lambda.Function(this, 'OAuthLambda', {
      runtime: lambda.Runtime.NODEJS_20_X,
      handler: 'index.handler',
      code: lambda.Code.fromAsset(path.join(__dirname, '..', 'lambda', 'oauth-callback')),
      timeout: cdk.Duration.seconds(10),
      memorySize: 256,
      environment: {
        COGNITO_USER_POOL_ID: props.userPool.userPoolId,
        COGNITO_DOMAIN: cognitoDomainFqdn,
        HMAC_SECRET: this.hmacSecret.secretValue.unsafeUnwrap(),
        SESSION_TTL_SECONDS: '3600',
      },
    });
    this.oauthLambda.addToRolePolicy(new iam.PolicyStatement({
      actions: [
        'cognito-idp:ListUserPoolClients',
        'cognito-idp:DescribeUserPoolClient',
      ],
      resources: [props.userPool.userPoolArn],
    }));

    // ---- OAuth Lambda Target Group ----
    // multi_value_headers.enabled = true: lets the Lambda return
    // multiple Set-Cookie via multiValueHeaders (the callback flow sets
    // BOTH cf_session and clears cf_oauth_state in one response).
    // The L2 TG construct does not surface this attribute, so we set
    // it on the underlying CfnTargetGroup. CDK's LambdaTarget also
    // auto-adds an AWS::Lambda::Permission for
    // `elasticloadbalancing.amazonaws.com` which we keep — it is
    // sufficient since the Lambda is inside our own account.
    const oauthTg = new elbv2.ApplicationTargetGroup(this, 'OAuthTg', {
      targets: [new elbv2Targets.LambdaTarget(this.oauthLambda)],
      targetType: elbv2.TargetType.LAMBDA,
    });
    const oauthTgCfn = oauthTg.node.defaultChild as elbv2.CfnTargetGroup;
    oauthTgCfn.targetGroupAttributes = [
      { key: 'lambda.multi_value_headers.enabled', value: 'true' },
    ];

    // ---- Listener rule: /oauth/* + X-Origin-Verify -> OAuth Lambda TG ----
    this.listener.addAction('OAuthRule', {
      priority: 1,
      conditions: [
        elbv2.ListenerCondition.pathPatterns(['/oauth/*']),
        elbv2.ListenerCondition.httpHeader('X-Origin-Verify', [originVerifyValue]),
      ],
      action: elbv2.ListenerAction.forward([oauthTg]),
    });

    // ---- code-server target group ----
    // The default listener action is "403 fail-closed" set above. We add
    // a catch-all rule with priority 1000 that forwards to this TG so
    // every request that did NOT match an /api/* or /oauth/* rule ends
    // up at code-server.
    const codeServerTg = new elbv2.ApplicationTargetGroup(this, 'CodeServerTg', {
      vpc,
      port: codeServerPort,
      protocol: elbv2.ApplicationProtocol.HTTP,
      targetType: elbv2.TargetType.INSTANCE,
      targets: [new elbv2Targets.InstanceIdTarget(props.ec2InstanceId, codeServerPort)],
      healthCheck: {
        path: '/healthz',
        healthyHttpCodes: '200,302,401',
        interval: cdk.Duration.seconds(30),
        timeout: cdk.Duration.seconds(5),
      },
    });
    // The catch-all matches BOTH path /* AND the CloudFront-injected
    // X-Origin-Verify header. Without the header check a request that
    // bypasses CloudFront would fall through to code-server. Pairing
    // path with the header turns the catch-all into a CloudFront-only
    // path; everything else falls back to the listener default (403).
    this.listener.addAction('CodeServerCatchAll', {
      priority: 1000,
      conditions: [
        elbv2.ListenerCondition.pathPatterns(['/*']),
        elbv2.ListenerCondition.httpHeader('X-Origin-Verify', [originVerifyValue]),
      ],
      action: elbv2.ListenerAction.forward([codeServerTg]),
    });

    // ---- App target groups + listener rules ----
    // Priorities start at 10 to leave room for future /oauth/v2/* etc.
    // (priority 1 = OAuth, priority 1000 = code-server catch-all).
    appRoutes.forEach((route, idx) => {
      const tgId = `${capitalize(route.name)}Tg`;
      const tg = new elbv2.ApplicationTargetGroup(this, tgId, {
        vpc,
        port: route.port,
        protocol: elbv2.ApplicationProtocol.HTTP,
        targetType: elbv2.TargetType.INSTANCE,
        targets: [new elbv2Targets.InstanceIdTarget(props.ec2InstanceId, route.port)],
        healthCheck: {
          path: route.healthCheckPath ?? '/health',
          // Permissive matcher: containers may return 401 (auth) or 404
          // (path not implemented at boot) before they fully initialize.
          // We just need to know the port is open and answering.
          healthyHttpCodes: '200,302,401,404',
          interval: cdk.Duration.seconds(30),
          timeout: cdk.Duration.seconds(5),
          // App boot can be slow (model download / compile). Don't yank
          // a healthy target on a transient blip.
          unhealthyThresholdCount: 5,
        },
      });

      // Listener rule: path match + X-Origin-Verify header match
      this.listener.addAction(`${capitalize(route.name)}Rule`, {
        priority: idx + 10,
        conditions: [
          elbv2.ListenerCondition.pathPatterns([route.pathPattern]),
          elbv2.ListenerCondition.httpHeader('X-Origin-Verify', [originVerifyValue]),
        ],
        action: elbv2.ListenerAction.forward([tg]),
      });
    });

    if (props.project) cdk.Tags.of(this).add('Project', props.project);
    if (props.purpose) cdk.Tags.of(this).add('Purpose', props.purpose);

    // ---- Outputs ----
    new cdk.CfnOutput(this, 'AlbArn', {
      value: this.alb.loadBalancerArn,
      description: 'Internal ALB ARN; consumed by CloudFrontFrontendStack',
      exportName: `${id}-AlbArn`,
    });
    new cdk.CfnOutput(this, 'AlbDnsName', {
      value: this.alb.loadBalancerDnsName,
      description: 'Internal ALB DNS (NOT publicly reachable; SG has zero ingress at this stage)',
    });
    new cdk.CfnOutput(this, 'AlbSecurityGroupId', {
      value: this.albSecurityGroup.securityGroupId,
      description: 'ALB SG ID; CloudFrontFrontendStack adds inbound to this',
      exportName: `${id}-AlbSgId`,
    });
    new cdk.CfnOutput(this, 'OriginVerifySecretArn', {
      value: this.originVerifySecret.secretArn,
      description: 'Secret containing the CloudFront -> ALB shared header value',
      exportName: `${id}-OriginVerifySecretArn`,
    });
    new cdk.CfnOutput(this, 'HmacSessionSecretArn', {
      value: this.hmacSecret.secretArn,
      description: 'HMAC secret shared with CloudFront Function (frontend stack reads at synth)',
      exportName: `${id}-HmacSessionSecretArn`,
    });
    new cdk.CfnOutput(this, 'OAuthLambdaArn', {
      value: this.oauthLambda.functionArn,
      description: 'OAuth Lambda (ALB Lambda Target) — for log inspection in CloudWatch',
    });
    new cdk.CfnOutput(this, 'AppRoutes', {
      value: JSON.stringify(
        appRoutes.map((r) => ({ name: r.name, path: r.pathPattern, port: r.port })),
      ),
      description: 'JSON manifest of app path routes for downstream stacks',
    });
  }
}

function capitalize(s: string): string {
  return s.charAt(0).toUpperCase() + s.slice(1);
}
