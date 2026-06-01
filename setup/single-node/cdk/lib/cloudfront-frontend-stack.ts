import * as path from 'path';
import * as fs from 'fs';
import * as cdk from 'aws-cdk-lib';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as ec2 from 'aws-cdk-lib/aws-ec2';
import * as elbv2 from 'aws-cdk-lib/aws-elasticloadbalancingv2';
import * as cloudfront from 'aws-cdk-lib/aws-cloudfront';
import * as origins from 'aws-cdk-lib/aws-cloudfront-origins';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Construct } from 'constructs';

export interface CloudFrontFrontendStackProps extends cdk.StackProps {
  /** Existing Cognito UserPool from CognitoOperatorStack. */
  readonly userPool: cognito.UserPool;
  /**
   * Internal ALB L2 reference from AlbBackendStack. Passed directly
   * (not via ARN string) so we avoid fromLookup which forbids tokens.
   */
  readonly alb: elbv2.IApplicationLoadBalancer;
  /** Internal ALB SG id from AlbBackendStack (we add CloudFront prefix list inbound). */
  readonly albSecurityGroupId: string;
  /** Origin verification secret (CloudFront -> ALB) from AlbBackendStack. */
  readonly originVerifySecret: secretsmanager.ISecret;
  /**
   * HMAC-SHA256 secret owned by AlbBackendStack and consumed here to
   * inline into the CloudFront Function source at synth time. The
   * SAME secret is set as an env var on the OAuth Lambda living in
   * AlbBackendStack so cookie issuance and verification stay in sync.
   */
  readonly hmacSecret: secretsmanager.ISecret;
  /** Tags. */
  readonly project?: string;
  readonly purpose?: string;
}

/**
 * CloudFrontFrontendStack (ADR-005 + ADR-011).
 *
 * Wires the public-facing entry to the validation environment:
 *
 *   browser -- HTTPS *.cloudfront.net --> CloudFront Distribution
 *     viewer-request  : CloudFront Function (HMAC-SHA256 verify of cf_session)
 *                       NOT attached to /oauth/* (auth bypass)
 *     default         : VPC Origin -> internal ALB :80 (X-Origin-Verify header)
 *
 *   The ALB owns ALL routing — /oauth/*, /api/*, and the code-server
 *   catch-all. There is no separate FunctionUrlOrigin (ADR-011).
 *
 * Why this stack stays self-contained
 *   - Inlines the HMAC secret (owned by AlbBackendStack) into the CF
 *     Function source. Rotation = update the secret in AlbBackendStack
 *     then redeploy BOTH stacks.
 *   - Creates the UserPoolClient HERE, not in CognitoOperatorStack,
 *     because the callback URL only exists once the Distribution is
 *     synthesized. Doing it in CognitoOperatorStack would force a
 *     deploy-then-edit-then-redeploy loop (ADR-005).
 *   - Mutates the imported ALB SG to add an inbound rule for the
 *     CloudFront origin-facing managed prefix list. This is the ONLY
 *     opening into the ALB (ADR-007), so all upstream traffic must
 *     pass through this Distribution.
 *
 * Why no WAF here
 *   ADR-009: validation phase keeps WAF out so iteration is fast and
 *   we don't pay for managed rule subscriptions during sandbox runs.
 *   Layers #2-#6 of ADR-008 carry the load.
 */
export class CloudFrontFrontendStack extends cdk.Stack {
  public readonly distribution: cloudfront.Distribution;
  public readonly userPoolClient: cognito.UserPoolClient;

  constructor(scope: Construct, id: string, props: CloudFrontFrontendStackProps) {
    super(scope, id, props);

    // ---------------------------------------------------------------
    // 1. CloudFront Function (viewer-request HMAC verify)
    // ---------------------------------------------------------------
    // Inline the HMAC secret (owned by AlbBackendStack) into the CF
    // Function source. We use literal string replace, NOT JSON.stringify,
    // because the CF Function runtime is plain JS and the secret is
    // alphanumeric (excludePunctuation in AlbBackendStack).
    const hmacSecretValue = props.hmacSecret.secretValue.unsafeUnwrap();
    const cfFunctionTemplate = fs.readFileSync(
      path.join(__dirname, '..', 'cf-functions', 'viewer-request.template.js'),
      'utf8',
    );
    // String.replace は最初の 1 回だけ置換する仕様。template の line 14 にも
    // コメントとして __HMAC_SECRET__ が出てくるので、global replace にしないと
    // line 22 の var HMAC_SECRET 側が placeholder のまま残り、CF Function が
    // ランタイムで 503 を返す (cookie 検証が無効な secret で走り、結果として
    // viewer-request stage 全体が壊れる)。
    const cfFunctionCode = cfFunctionTemplate.split('__HMAC_SECRET__').join(hmacSecretValue);
    const viewerRequestFn = new cloudfront.Function(this, 'ViewerRequestFn', {
      code: cloudfront.FunctionCode.fromInline(cfFunctionCode),
      runtime: cloudfront.FunctionRuntime.JS_2_0,
      comment: 'HMAC verify cf_session cookie; redirect to /oauth/login if missing/invalid',
    });

    // ---------------------------------------------------------------
    // 2. VPC Origin (internal ALB)
    // ---------------------------------------------------------------
    // CloudFront VPC Origin (2024-11 GA) is the only way to reach an
    // internal ALB without a public DNS / cert (ADR-003). Origin custom
    // header X-Origin-Verify proves to the ALB listener that the
    // request actually traversed CloudFront (ADR-008 layer #5).
    const vpcOrigin = origins.VpcOrigin.withApplicationLoadBalancer(props.alb, {
      protocolPolicy: cloudfront.OriginProtocolPolicy.HTTP_ONLY,
      httpPort: 80,
      customHeaders: {
        'X-Origin-Verify': props.originVerifySecret.secretValue.unsafeUnwrap(),
      },
      // /stream/pipeline は Trainium EDIT/VLM の長い await (60-120s) を含み、
      // CF default 30s では origin read timeout で切られる。stream backend が
      // 10s 間隔で stage_progress heartbeat を吐くので、CF 上限の 60s で十分
      // (本番で更に伸ばす場合は service quota 引き上げが必要)。
      readTimeout: cdk.Duration.seconds(60),
    });

    // ---------------------------------------------------------------
    // 3. Distribution
    // ---------------------------------------------------------------
    // Single origin (VPC Origin -> ALB) handles both the default
    // behavior (code-server / app routes) and /oauth/*. The ONLY
    // difference for /oauth/* is that the CF Function is not attached
    // (auth bypass — viewer-request must not redirect during the
    // OAuth dance).
    this.distribution = new cloudfront.Distribution(this, 'FrontendDistribution', {
      defaultBehavior: {
        origin: vpcOrigin,
        viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
        allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
        // CACHING_DISABLED: code-server is interactive, model APIs are
        // POST-heavy. Caching here would just produce stale UI / wrong
        // tokenizer responses; default behaviour caches GET/HEAD only
        // anyway, but we prefer explicit no-cache.
        cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
        // ALL_VIEWER (not ALL_VIEWER_EXCEPT_HOST_HEADER) so the viewer
        // Host (dXXX.cloudfront.net) reaches the origin unchanged.
        // code-server's WebSocket origin verification compares the
        // viewer Origin header against the request Host — if Host is
        // rewritten to the ALB internal DNS, the upgrade fails with
        // 403 and the browser surfaces "WebSocket close 1006" (ADR-012).
        originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER,
        functionAssociations: [
          {
            function: viewerRequestFn,
            eventType: cloudfront.FunctionEventType.VIEWER_REQUEST,
          },
        ],
      },
      // /oauth/* uses the SAME origin (VPC Origin -> ALB) but does NOT
      // attach the viewer-request CF Function. The ALB listener rule
      // (priority 1, X-Origin-Verify match) routes /oauth/* to the
      // OAuth Lambda Target Group (ADR-011).
      additionalBehaviors: {
        '/oauth/*': {
          origin: vpcOrigin,
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
          cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
          // ALL_VIEWER (not ALL_VIEWER_EXCEPT_HOST_HEADER) so the
          // OAuth Lambda receives the original viewer Host
          // (dXXX.cloudfront.net). It uses that to construct
          // redirect_uri for the Cognito authorize / token calls.
          // The ALB listener rules route /oauth/* by path + the
          // X-Origin-Verify origin custom header — they do NOT
          // depend on Host, so forwarding the viewer Host is safe.
          originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER,
          // No functionAssociations: the OAuth dance must reach the
          // Lambda without a redirect-to-login loop.
        },
        // Neuron Explorer is interactive, profile-heavy, and cookie-
        // backed.  We share the same VPC Origin and the same HMAC
        // viewer-request function as the default behavior so a single
        // Cognito session covers both code-server and Explorer.
        '/explorer/*': {
          origin: vpcOrigin,
          viewerProtocolPolicy: cloudfront.ViewerProtocolPolicy.REDIRECT_TO_HTTPS,
          allowedMethods: cloudfront.AllowedMethods.ALLOW_ALL,
          cachePolicy: cloudfront.CachePolicy.CACHING_DISABLED,
          originRequestPolicy: cloudfront.OriginRequestPolicy.ALL_VIEWER,
          functionAssociations: [
            {
              function: viewerRequestFn,
              eventType: cloudfront.FunctionEventType.VIEWER_REQUEST,
            },
          ],
        },
      },
      // Default *.cloudfront.net cert (ADR-001). No alternate domain.
      // Geo restrictions / WAF are deliberately omitted (ADR-009).
      comment: `${id} — ADR-005 + ADR-011 frontend`,
      enableLogging: false,
      // Use only NA + EU edges to limit blast radius / costs during
      // validation. Switch to ALL when going wider.
      priceClass: cloudfront.PriceClass.PRICE_CLASS_100,
    });

    // ---------------------------------------------------------------
    // 4. UserPoolClient (callback URL = THIS distribution)
    // ---------------------------------------------------------------
    const cloudfrontDomain = this.distribution.domainName; // dXXXX.cloudfront.net
    const callbackUrl = `https://${cloudfrontDomain}/oauth/callback`;
    const logoutUrl = `https://${cloudfrontDomain}/`;

    this.userPoolClient = new cognito.UserPoolClient(this, 'OperatorClient', {
      userPool: props.userPool,
      generateSecret: true, // basic auth on token endpoint
      authFlows: { userPassword: false, userSrp: true, custom: false, adminUserPassword: false },
      oAuth: {
        flows: { authorizationCodeGrant: true, implicitCodeGrant: false, clientCredentials: false },
        scopes: [cognito.OAuthScope.OPENID, cognito.OAuthScope.EMAIL],
        callbackUrls: [callbackUrl],
        logoutUrls: [logoutUrl],
      },
      // Refresh tokens are unused (we re-auth on session cookie expiry)
      // but the API requires a value; 60 min keeps it tight.
      refreshTokenValidity: cdk.Duration.minutes(60),
      preventUserExistenceErrors: true,
    });

    // ---------------------------------------------------------------
    // 5. ALB SG inbound: CloudFront managed prefix list (ADR-007)
    // ---------------------------------------------------------------
    // This is the ONLY ingress on the ALB SG. Until this stack
    // deploys, the ALB SG has zero inbound (AlbBackendStack creates
    // it empty by design). Adding the prefix list is what "publishes"
    // the ALB as reachable, and only via CloudFront edges.
    const cloudfrontPrefixList = ec2.PrefixList.fromLookup(this, 'CloudFrontOriginFacing', {
      prefixListName: 'com.amazonaws.global.cloudfront.origin-facing',
    });
    const albSg = ec2.SecurityGroup.fromSecurityGroupId(
      this,
      'ImportedAlbSg',
      props.albSecurityGroupId,
      { mutable: true },
    );
    albSg.addIngressRule(
      ec2.Peer.prefixList(cloudfrontPrefixList.prefixListId),
      ec2.Port.tcp(80),
      // EC2 SG description charset is restricted (no >, <, etc.). Use plain ASCII.
      'CloudFront origin-facing prefix list to ALB port 80',
    );

    if (props.project) cdk.Tags.of(this).add('Project', props.project);
    if (props.purpose) cdk.Tags.of(this).add('Purpose', props.purpose);

    // ---------------------------------------------------------------
    // 6. Outputs
    // ---------------------------------------------------------------
    new cdk.CfnOutput(this, 'CloudFrontDomainName', {
      value: cloudfrontDomain,
      description: 'Public entry: https://<this>/  (operator browser)',
    });
    new cdk.CfnOutput(this, 'CloudFrontDistributionId', {
      value: this.distribution.distributionId,
      description: 'Distribution ID; use for invalidations',
    });
    new cdk.CfnOutput(this, 'CognitoCallbackUrl', {
      value: callbackUrl,
      description: 'Registered callback URL on UserPoolClient',
    });
    new cdk.CfnOutput(this, 'UserPoolClientId', {
      value: this.userPoolClient.userPoolClientId,
      description: 'UserPoolClient consumed by the OAuth Lambda (in AlbBackendStack)',
    });
  }
}
