import { test, expect } from '@playwright/test';
import { CognitoLoginPage } from '../pages/CognitoLoginPage';

const TEST_EMAIL = process.env.TEST_USER_EMAIL!;
const TEST_PASSWORD = process.env.TEST_USER_PASSWORD!;

// Verifies that the freshly deployed Next.js standalone bundle on EC2
// is reachable through CloudFront and the new presigned-S3 EDIT contract
// is wired end-to-end.
//
// Scope:
//   1. Auth via Cognito Hosted UI lands the browser on /edit.
//   2. /api/edit/engines responds 200 with the expected slots.
//   3. The page exposes the 3-slot toolbar + ImageDropzone / VoiceRecorder.
//
// Out of scope (kept for a separate spec or manual run):
//   - Real audio capture / Bedrock invocation. ASR + Nova Canvas need
//     real media flows; we sanity-check the static page surface here.
test.describe('voice-image-edit /edit page (post-deploy)', () => {
  test.setTimeout(120_000);
  test('lands on /edit after Cognito and shows pipeline UI', async ({ page, context }) => {
    await context.clearCookies();

    await page.goto('/edit', { waitUntil: 'networkidle' });

    const cognito = new CognitoLoginPage(page);
    // Cognito Hosted UI loads its CSS asynchronously; give it a moment
    // before the locator query.
    await page.waitForLoadState('networkidle');
    await cognito.expectVisible();
    await cognito.login(TEST_EMAIL, TEST_PASSWORD);

    await page.waitForURL((u) => !u.host.includes('amazoncognito.com'), { timeout: 30_000 });
    await page.waitForLoadState('networkidle');

    // After OAuth the browser is back on CloudFront. Some configs land
    // on `/` after callback; navigate to /edit explicitly to assert it
    // is reachable behind the cookie.
    if (!page.url().endsWith('/edit')) {
      await page.goto('/edit', { waitUntil: 'networkidle' });
    }

    // Static page surface — these strings are part of EditPage in
    // app/frontend/src/app/edit/page.tsx.
    await expect(page.getByRole('heading', { name: '音声で画像を編集' })).toBeVisible();
    await expect(page.getByText('A. 画像 (BEFORE)')).toBeVisible();
    await expect(page.getByText('B. 編集指示 (音声)')).toBeVisible();
    await expect(page.getByText('D. パイプライン進捗')).toBeVisible();

    // /api/edit/engines must come back 200 with the expected slots.
    const enginesRes = await page.request.get('/api/edit/engines');
    expect(enginesRes.status(), 'engines API should be 200').toBe(200);
    const json = await enginesRes.json();
    expect(json).toHaveProperty('slots');
    expect(json.slots).toHaveProperty('asr');
    expect(json.slots).toHaveProperty('vlm');
    expect(json.slots).toHaveProperty('edit');
  });
});
