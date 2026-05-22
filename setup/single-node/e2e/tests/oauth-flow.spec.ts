import { test, expect } from '@playwright/test';
import { CognitoLoginPage } from '../pages/CognitoLoginPage';
import { CodeServerPage } from '../pages/CodeServerPage';

const TEST_EMAIL = process.env.TEST_USER_EMAIL!;
const TEST_PASSWORD = process.env.TEST_USER_PASSWORD!;

// Happy path: a fresh browser visiting the CloudFront root must end up
// at code-server, having traversed:
//   GET /                 -> 302 to /oauth/login   (CF Function: no cookie)
//   GET /oauth/login      -> 302 to Cognito Hosted UI (Lambda)
//   <Cognito form submit> -> 302 to /oauth/callback (Cognito redirects)
//   GET /oauth/callback   -> 302 to /                (Lambda issues cf_session)
//   GET /                 -> 200 from ALB (CF Function verifies cookie)
//
// We don't pin every redirect URL; we assert the *outcome*: cookie set,
// code-server reachable. Pinning intermediate URLs would couple the
// test to Cognito's domain shape and make migrations harder.
test.describe('OAuth proxy happy path', () => {
  test('fresh visit lands on code-server after Cognito login', async ({ page, context }) => {
    // Make sure no leftover state from a previous run leaks in.
    await context.clearCookies();

    await page.goto('/', { waitUntil: 'domcontentloaded' });

    // We expect to be on the Cognito Hosted UI now. URL contains
    // amazoncognito.com - we check the form, not the URL host, so the
    // assertion holds even if AWS migrates Hosted UI domains.
    const cognito = new CognitoLoginPage(page);
    await cognito.expectVisible();

    // Guard against a force-change-password state. If we hit this, the
    // operator forgot to admin-set-user-password; fail fast with a
    // clear message instead of getting stuck in the form.
    if (await cognito.forceChangeBanner.isVisible().catch(() => false)) {
      throw new Error(
        'Cognito is showing the force-change-password screen. Run:\n' +
          '  aws cognito-idp admin-set-user-password \\\n' +
          '      --user-pool-id <ID> --username <EMAIL> \\\n' +
          '      --password <PW> --permanent\n',
      );
    }

    await cognito.login(TEST_EMAIL, TEST_PASSWORD);

    // Wait until we're back on the CloudFront origin. Once cf_session
    // is set the CF Function lets us through to the ALB.
    await page.waitForURL((url) => url.host !== '' && !url.host.includes('amazoncognito.com'), {
      timeout: 30_000,
    });

    // The cf_session cookie must now exist on the CloudFront domain.
    const cookies = await context.cookies();
    const session = cookies.find((c) => c.name === 'cf_session');
    expect(session, 'cf_session cookie should be set after callback').toBeDefined();
    expect(session!.httpOnly, 'cf_session must be HttpOnly').toBe(true);
    expect(session!.secure, 'cf_session must be Secure').toBe(true);
    // sameSite is normalized differently by browsers; just confirm it
    // is set to one of the lax/strict values, never None.
    expect(['Lax', 'Strict']).toContain(session!.sameSite);
    // Body.<sig> shape - exactly one dot, no spaces.
    expect(session!.value).toMatch(/^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);

    const codeServer = new CodeServerPage(page);
    await codeServer.expectReached();
  });
});
