// Hard-fail if the deploy outputs aren't supplied. We want the operator
// to see the missing env var name, not chase a "page.goto undefined" error.

const REQUIRED = ['CF_BASE_URL', 'TEST_USER_EMAIL', 'TEST_USER_PASSWORD'];

export default async function globalSetup() {
  const missing = REQUIRED.filter((k) => !process.env[k]);
  if (missing.length > 0) {
    throw new Error(
      `Missing required env vars: ${missing.join(', ')}.\n\n` +
        `Set them after the CloudFront frontend stack is deployed:\n` +
        `  export CF_BASE_URL=https://$(aws cloudformation describe-stacks \\\n` +
        `      --stack-name <STACK>-frontend --region <REGION> \\\n` +
        `      --query 'Stacks[0].Outputs[?OutputKey==\`CloudFrontDomainName\`].OutputValue' --output text)\n` +
        `  export TEST_USER_EMAIL=op@example.com\n` +
        `  export TEST_USER_PASSWORD='...'  # set via admin-set-user-password\n`,
    );
  }
  // Surface the resolved targets for log clarity.
  // eslint-disable-next-line no-console
  console.log(`[e2e] CF_BASE_URL = ${process.env.CF_BASE_URL}`);
  // eslint-disable-next-line no-console
  console.log(`[e2e] TEST_USER_EMAIL = ${process.env.TEST_USER_EMAIL}`);
}
