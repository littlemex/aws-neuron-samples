// CloudFormation Custom Resource: Cognito operator user bootstrap.
//
// On Create / Update:
//   1. AdminCreateUser (MessageAction=SUPPRESS, email_verified=true)
//      Idempotent: UsernameExistsException is treated as success so a
//      second deploy with the same email simply re-applies the password.
//   2. AdminSetUserPassword (Permanent=true)
//      Bypasses the FORCE_CHANGE_PASSWORD challenge so the operator can
//      log in immediately via the Hosted UI.
//
// On Delete:
//   No-op. The UserPool is destroyed by CFN; the user disappears with it.
//   We deliberately do not AdminDeleteUser to keep the Custom Resource
//   harmless on stack delete (avoids spurious failures if the pool is
//   already gone or if the operator changed the email out-of-band).
//
// Inputs (ResourceProperties):
//   UserPoolId  - target UserPool id
//   Email       - operator email (also used as the username)
//   PasswordSecretArn - Secrets Manager ARN whose SecretString IS the
//                       desired permanent password. Reading happens here
//                       (not at synth) so the password never lands in the
//                       CFN template.

import {
  CognitoIdentityProviderClient,
  AdminCreateUserCommand,
  AdminSetUserPasswordCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import {
  SecretsManagerClient,
  GetSecretValueCommand,
} from '@aws-sdk/client-secrets-manager';

const region = process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION;
const cognito = new CognitoIdentityProviderClient({ region });
const secrets = new SecretsManagerClient({ region });

export const handler = async (event) => {
  const requestType = event.RequestType;
  const props = event.ResourceProperties || {};
  const physicalId =
    event.PhysicalResourceId || `cognito-bootstrap-${props.UserPoolId}-${props.Email}`;

  if (requestType === 'Delete') {
    return { PhysicalResourceId: physicalId };
  }

  const userPoolId = props.UserPoolId;
  const email = props.Email;
  const passwordSecretArn = props.PasswordSecretArn;

  if (!userPoolId || !email || !passwordSecretArn) {
    throw new Error(
      'Missing required ResourceProperties: UserPoolId, Email, PasswordSecretArn',
    );
  }

  const secretValue = await secrets.send(
    new GetSecretValueCommand({ SecretId: passwordSecretArn }),
  );
  const password = secretValue.SecretString;
  if (!password) {
    throw new Error(`Secret ${passwordSecretArn} has empty SecretString`);
  }

  try {
    await cognito.send(
      new AdminCreateUserCommand({
        UserPoolId: userPoolId,
        Username: email,
        UserAttributes: [
          { Name: 'email', Value: email },
          { Name: 'email_verified', Value: 'true' },
        ],
        MessageAction: 'SUPPRESS',
      }),
    );
  } catch (e) {
    if (e.name !== 'UsernameExistsException') {
      throw e;
    }
  }

  await cognito.send(
    new AdminSetUserPasswordCommand({
      UserPoolId: userPoolId,
      Username: email,
      Password: password,
      Permanent: true,
    }),
  );

  return {
    PhysicalResourceId: physicalId,
    Data: { Email: email },
  };
};
