import * as path from 'path';
import * as cdk from 'aws-cdk-lib';
import * as cognito from 'aws-cdk-lib/aws-cognito';
import * as iam from 'aws-cdk-lib/aws-iam';
import * as lambda from 'aws-cdk-lib/aws-lambda';
import * as logs from 'aws-cdk-lib/aws-logs';
import * as secretsmanager from 'aws-cdk-lib/aws-secretsmanager';
import { Provider } from 'aws-cdk-lib/custom-resources';
import { Construct } from 'constructs';

export interface CognitoOperatorStackProps extends cdk.StackProps {
  /**
   * Cognito Hosted UI subdomain prefix. The full FQDN ends up as
   * `<prefix>.auth.<region>.amazoncognito.com`. The prefix must be
   * globally unique within the region. Default = `${stackName}-ops`.
   *
   * The prefix is the only knob the operator picks; everything else
   * (cert, DNS) is handled by AWS so this stack stays domain-free per
   * ADR-001.
   */
  readonly domainPrefix?: string;

  /**
   * Optional one-shot operator bootstrap.
   *
   * When BOTH `operatorEmail` and `operatorPasswordSecretArn` are
   * provided, the stack creates a Cognito user (email_verified=true,
   * password=Permanent) at deploy time so the deployer can log in via
   * the Hosted UI immediately — no out-of-band admin-create-user call
   * needed (ADR-013).
   *
   * The password is read from Secrets Manager at runtime (inside the
   * Lambda-backed Custom Resource) so it never lands in the CFN
   * template, cdk.out, or drift detection diffs.
   */
  readonly operatorEmail?: string;
  readonly operatorPasswordSecretArn?: string;

  readonly project?: string;
  readonly purpose?: string;
}

/**
 * Cognito UserPool + Hosted UI domain for operator authentication.
 *
 * Per ADR-005 the OAuth dance is:
 *   browser  -- /oauth/login  -->  CloudFront
 *   CloudFront  -- 302  -->  Cognito Hosted UI (*.amazoncognito.com)
 *   Hosted UI  -- code  -->  CloudFront /oauth/callback (Lambda)
 *   Lambda    -- HMAC cookie  -->  browser
 *
 * This stack provides the UserPool + Hosted UI domain. The
 * UserPoolClient is intentionally created in CloudFrontFrontendStack
 * because the callback URL (`https://dXXXX.cloudfront.net/oauth/callback`)
 * is only known after CloudFront synthesizes the distribution. Doing it
 * here would force a deploy-then-edit-then-redeploy loop.
 *
 * Self-signup is disabled. Operators are created either:
 *   (a) via the optional one-shot Custom Resource at deploy time when
 *       `operatorEmail` + `operatorPasswordSecretArn` are passed, or
 *   (b) out-of-band via `aws cognito-idp admin-create-user` for any
 *       additional accounts.
 */
export class CognitoOperatorStack extends cdk.Stack {
  public readonly userPool: cognito.UserPool;
  public readonly userPoolDomain: cognito.UserPoolDomain;

  constructor(scope: Construct, id: string, props: CognitoOperatorStackProps) {
    super(scope, id, props);

    this.userPool = new cognito.UserPool(this, 'OperatorUserPool', {
      userPoolName: `${id}-operators`,
      // Operators are created administratively. Self-signup would let an
      // attacker who reaches /oauth/login (after passing WAF) register
      // themselves; we want a hard "admin only" gate.
      selfSignUpEnabled: false,
      signInAliases: { email: true, username: false },
      autoVerify: { email: true },
      standardAttributes: {
        email: { required: true, mutable: false },
      },
      passwordPolicy: {
        minLength: 12,
        requireLowercase: true,
        requireUppercase: true,
        requireDigits: true,
        requireSymbols: false,
        tempPasswordValidity: cdk.Duration.days(2),
      },
      mfa: cognito.Mfa.OPTIONAL,
      mfaSecondFactor: { sms: false, otp: true },
      accountRecovery: cognito.AccountRecovery.EMAIL_ONLY,
      // Detroying the UserPool wipes operator accounts. For a validation
      // sandbox that is desirable (clean re-deploy). For production, swap
      // to RETAIN before any operator account is real.
      removalPolicy: cdk.RemovalPolicy.DESTROY,
      deletionProtection: false,
    });

    // Hosted UI on *.amazoncognito.com. The prefix must be globally
    // unique inside the region. AWS rejects any prefix containing the
    // substrings `aws`, `amazon`, or `cognito`, so we strip those plus
    // an `-ops` suffix to keep it short and intent-revealing. The user
    // can always override via -c cognitoDomainPrefix=<custom>.
    const sanitized = id
      .toLowerCase()
      .replace(/[^a-z0-9-]/g, '-')
      .replace(/cognito/g, '')
      .replace(/amazon/g, '')
      .replace(/aws/g, '')
      .replace(/-+/g, '-')
      .replace(/^-|-$/g, '')
      .slice(0, 28); // leave headroom for the `-ops` suffix
    const desiredPrefix = props.domainPrefix ?? `${sanitized}-ops`;

    this.userPoolDomain = this.userPool.addDomain('HostedUiDomain', {
      cognitoDomain: { domainPrefix: desiredPrefix },
    });

    // ---------------------------------------------------------------
    // Optional: one-shot operator bootstrap (ADR-013)
    // ---------------------------------------------------------------
    // Triggered only when BOTH email and password Secret ARN are passed.
    // Half-configured cases (only email, or only ARN) are treated as
    // "no bootstrap" rather than a hard error so a partial config from
    // deploy.sh does not block stack creation.
    if (props.operatorEmail && props.operatorPasswordSecretArn) {
      const passwordSecret = secretsmanager.Secret.fromSecretCompleteArn(
        this,
        'OperatorPasswordSecret',
        props.operatorPasswordSecretArn,
      );

      const bootstrapFn = new lambda.Function(this, 'OperatorBootstrapFn', {
        runtime: lambda.Runtime.NODEJS_20_X,
        handler: 'index.handler',
        code: lambda.Code.fromAsset(
          path.join(__dirname, '..', 'lambda', 'cognito-bootstrap-user'),
        ),
        timeout: cdk.Duration.seconds(30),
        memorySize: 256,
        logRetention: logs.RetentionDays.ONE_WEEK,
      });

      bootstrapFn.addToRolePolicy(
        new iam.PolicyStatement({
          actions: [
            'cognito-idp:AdminCreateUser',
            'cognito-idp:AdminSetUserPassword',
          ],
          resources: [this.userPool.userPoolArn],
        }),
      );
      passwordSecret.grantRead(bootstrapFn);

      const provider = new Provider(this, 'OperatorBootstrapProvider', {
        onEventHandler: bootstrapFn,
        logRetention: logs.RetentionDays.ONE_WEEK,
      });

      // The CR's PhysicalResourceId encodes (UserPoolId, Email) so that
      // changing the email triggers a Replace (which on Delete is a
      // no-op, then Create runs against the new email). Changing the
      // password Secret ARN must trigger Update because the Lambda has
      // to re-read the secret — putting the ARN in ResourceProperties
      // accomplishes that.
      new cdk.CustomResource(this, 'OperatorBootstrap', {
        serviceToken: provider.serviceToken,
        resourceType: 'Custom::CognitoOperatorBootstrap',
        properties: {
          UserPoolId: this.userPool.userPoolId,
          Email: props.operatorEmail,
          PasswordSecretArn: props.operatorPasswordSecretArn,
        },
      });

      new cdk.CfnOutput(this, 'OperatorEmail', {
        value: props.operatorEmail,
        description: 'Bootstrapped operator email (Hosted UI sign-in)',
      });
    }

    if (props.project) cdk.Tags.of(this).add('Project', props.project);
    if (props.purpose) cdk.Tags.of(this).add('Purpose', props.purpose);

    new cdk.CfnOutput(this, 'UserPoolId', {
      value: this.userPool.userPoolId,
      description: 'Cognito UserPool ID; consumed by CloudFrontFrontendStack',
      exportName: `${id}-UserPoolId`,
    });
    new cdk.CfnOutput(this, 'UserPoolArn', {
      value: this.userPool.userPoolArn,
      description: 'Cognito UserPool ARN; consumed by CloudFrontFrontendStack',
      exportName: `${id}-UserPoolArn`,
    });
    new cdk.CfnOutput(this, 'UserPoolDomain', {
      value: this.userPoolDomain.domainName,
      description:
        'Cognito Hosted UI prefix. Full FQDN is ' +
        '<this>.auth.<region>.amazoncognito.com',
      exportName: `${id}-UserPoolDomain`,
    });
    new cdk.CfnOutput(this, 'HostedUiBaseUrl', {
      value: `https://${this.userPoolDomain.domainName}.auth.${this.region}.amazoncognito.com`,
      description: 'Hosted UI base URL (operators authenticate here)',
    });
  }
}
