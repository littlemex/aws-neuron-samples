import { test, expect } from '@playwright/test';
import fs from 'fs';
import path from 'path';
import { CognitoLoginPage } from '../pages/CognitoLoginPage';

const TEST_EMAIL = process.env.TEST_USER_EMAIL!;
const TEST_PASSWORD = process.env.TEST_USER_PASSWORD!;

// Where to write the production-quality screenshots that the Zenn
// book pulls in.  Keep it inside artifacts/ so CI can publish them.
const SHOTS_DIR = path.join(
  process.cwd(),
  'artifacts',
  'explorer-screenshots',
);
fs.mkdirSync(SHOTS_DIR, { recursive: true });

async function loginViaCognito(page: import('@playwright/test').Page) {
  await page.goto('/explorer/', { waitUntil: 'domcontentloaded' });
  const cognito = new CognitoLoginPage(page);
  await cognito.expectVisible();
  await cognito.login(TEST_EMAIL, TEST_PASSWORD);
  await page.waitForURL(
    (url) => !url.host.includes('amazoncognito.com'),
    { timeout: 30_000 },
  );
}

test.describe('Neuron Explorer - smoke', () => {
  test.beforeEach(async ({ context }) => {
    await context.clearCookies();
  });

  test('GET /explorer/ without cookie redirects to /oauth/login', async ({ request }) => {
    // Same fail-closed contract as the rest of the surface.  Without
    // cf_session the CF Function must redirect; the ALB never sees us.
    const r = await request.get('/explorer/', { maxRedirects: 0 });
    expect(r.status()).toBe(302);
    expect(r.headers()['location']).toContain('/oauth/login');
  });

  test('after Cognito login the SPA shell is reachable', async ({ page }) => {
    await loginViaCognito(page);
    await page.goto('/explorer/', { waitUntil: 'domcontentloaded' });

    // The shell title is set in the inline HTML head.
    await expect(page).toHaveTitle(/Neuron Explorer UI/i);

    // Profile Manager is the default landing.  We assert the heading
    // rather than a specific row count so the test stays green even
    // when the seed profile bundle changes.
    await page.goto('/explorer/profiles', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(3000);
    await expect(
      page.getByRole('heading', { name: 'Profile Manager' }).first(),
    ).toBeVisible({ timeout: 10_000 });
  });

  test('the API behind /explorer/api/ responds via CloudFront', async ({ page, request }) => {
    await loginViaCognito(page);
    // Use page.request so the cf_session cookie set during login is
    // attached automatically.  Bare APIRequestContext would not.
    const cookies = await page.context().cookies();
    expect(cookies.some((c) => c.name === 'cf_session'), 'cf_session must be set').toBe(true);

    const r = await page.request.get('/explorer/api/v1/profiles/search');
    expect(r.status(), 'profiles search must respond').toBe(200);
    const json = await r.json();
    // The search endpoint always returns { count, data } even when
    // the data is null / empty.  We only assert on shape.
    expect(json).toHaveProperty('count');
    expect(json).toHaveProperty('data');
  });
});

test.describe('Neuron Explorer - reference screenshots', () => {
  // These tests double as the screenshot generator that feeds the
  // Zenn book.  They are tagged so CI can run them on demand without
  // polluting the standard test report.
  test.describe.configure({ tag: ['@screenshots'] });

  test.beforeEach(async ({ context }) => {
    await context.clearCookies();
  });

  test('capture profile manager + summary + profile detail', async ({ page }) => {
    await loginViaCognito(page);
    await page.setViewportSize({ width: 1600, height: 1000 });

    const shot = async (name: string) => {
      const file = path.join(SHOTS_DIR, `${name}.png`);
      await page.screenshot({ path: file, fullPage: true });
    };

    await page.goto('/explorer/profiles', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(4000);
    await shot('01-profile-manager');

    for (const tab of ['Search Profiles', 'User Favourite', 'User History']) {
      try {
        await page.getByRole('tab', { name: tab }).click({ timeout: 3000 });
        await page.waitForTimeout(2500);
        const safe = tab.toLowerCase().replace(/[^a-z0-9]+/g, '-');
        await shot(`02-tab-${safe}`);
      } catch {
        /* empty manager ok */
      }
    }

    await page.goto('/explorer/summary', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(4000);
    await shot('03-summary');

    await page.goto('/explorer/profile', { waitUntil: 'domcontentloaded' });
    await page.waitForTimeout(4000);
    await shot('04-profile-empty');

    // Best-effort: attempt to open the seed profile if the upload-time
    // pre-seed step succeeded.  Falls back gracefully when there is no
    // matching session id under the user's context.
    const seed = process.env.EXPLORER_SEED_SESSION_ID;
    if (seed) {
      await page.goto(`/explorer/profile/${seed}`, { waitUntil: 'domcontentloaded' });
      await page.waitForTimeout(8000);
      await shot('05-profile-detail');
    }
  });
});
