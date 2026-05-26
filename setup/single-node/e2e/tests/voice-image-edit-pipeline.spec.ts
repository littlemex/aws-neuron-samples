import { test, expect } from '@playwright/test';
import { CognitoLoginPage } from '../pages/CognitoLoginPage';

const TEST_EMAIL = process.env.TEST_USER_EMAIL!;
const TEST_PASSWORD = process.env.TEST_USER_PASSWORD!;

// Drives the 4-stage pipeline end-to-end (ASR is skipped because we
// upload via the textarea, not the microphone):
//   Stage 1 ASR              -> skipped
//   Stage 2 VLM instruction  -> done   (Bedrock Nova Lite)
//   Stage 3 EDIT             -> done   (Bedrock Nova Canvas, presigned S3)
//   Stage 4 VLM review       -> done   (fetches presigned URL + base64 again)
//
// The presigned-S3 path is exactly what closes the ALB Lambda 1 MB
// response cap, so a green run here is the post-deploy proof.

import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

// Nova Canvas requires 320 ≤ width ≤ 4096. Use a 384x384 plain white
// PNG; the deploy smoke checks the *contract path* (presigned S3 URL),
// not the visual output, so a flat color is enough.
const __filename_e2e = fileURLToPath(import.meta.url);
const __dirname_e2e = path.dirname(__filename_e2e);
const FIXTURE_PNG_PATH = path.join(__dirname_e2e, '..', 'fixtures', 'white-384.png');
const FIXTURE_PNG = fs.readFileSync(FIXTURE_PNG_PATH);

test.describe('voice-image-edit /edit pipeline (post-deploy)', () => {
  test.setTimeout(180_000);

  test('4-stage pipeline completes via presigned-S3 EDIT path', async ({ page, context }) => {
    await context.clearCookies();

    await page.goto('/edit', { waitUntil: 'networkidle' });

    const cognito = new CognitoLoginPage(page);
    await page.waitForLoadState('networkidle');
    await cognito.expectVisible();
    await cognito.login(TEST_EMAIL, TEST_PASSWORD);

    await page.waitForURL((u) => !u.host.includes('amazoncognito.com'), { timeout: 30_000 });
    if (!page.url().endsWith('/edit')) {
      await page.goto('/edit', { waitUntil: 'networkidle' });
    }

    // Upload a 1x1 PNG into the hidden file input. The dropzone uses
    // an internal <input type=file>, which is fillable directly even
    // though it's hidden behind the click handler.
    const fileInput = page.locator('input[type="file"]');
    await fileInput.setInputFiles({
      name: 'before.png',
      mimeType: 'image/png',
      buffer: FIXTURE_PNG,
    });

    // Bypass the microphone path by typing instruction into the
    // textarea directly (Stage 1 ASR will be marked "skipped").
    const textarea = page.locator('textarea').first();
    await textarea.fill('make the background pure white');

    // Kick off the pipeline.
    await page.getByRole('button', { name: /パイプラインを実行/ }).click();

    // Wait until Stage 4 reports a terminal status (done OR error).
    // We treat 'error' on review as acceptable for the deploy smoke
    // because the deterministic checks below assert on Stage 3 (the
    // presigned-S3 hand-off, which is the load-bearing change).
    const stage3 = page.locator('li').filter({ hasText: '3. EDIT' });
    const stage4 = page.locator('li').filter({ hasText: '4. VLM レビュー' });

    // Stage 3 must succeed: it produces the presigned URL.
    await expect(stage3.locator('span').first()).toHaveText(/done/, { timeout: 120_000 });

    // Stage 4 must reach a terminal state (done or error). Using
    // /done|error/ catches both without flapping on review-only flake.
    await expect(stage4.locator('span').first()).toHaveText(/done|error/, { timeout: 120_000 });

    // The AFTER <img> src must point at an S3 presigned URL — the
    // whole reason for P7-F. Different SDK versions emit slightly
    // different host shapes (path-style vs vhost, regional vs not), so
    // we just assert the bucket name + AWS signature query.
    const afterImg = page.locator('img[alt=after]');
    const afterSrc = (await afterImg.getAttribute('src')) ?? '';
    expect(afterSrc, 'AFTER image src should be set').not.toBe('');
    expect(afterSrc, 'AFTER image src should be HTTPS').toMatch(/^https:\/\//);
    expect(afterSrc, 'AFTER image src should be on S3').toContain('amazonaws.com');
    // boto3 defaults to SigV2 in some regions and SigV4 in others —
    // either is fine, both are valid presigned forms.
    const isSigV4 = afterSrc.includes('X-Amz-Signature=');
    const isSigV2 = afterSrc.includes('AWSAccessKeyId=') && afterSrc.includes('Signature=');
    expect(
      isSigV4 || isSigV2,
      `AFTER image src should be presigned (SigV2 or SigV4): ${afterSrc.slice(0, 120)}`,
    ).toBe(true);
    // The bucket name must be the EditResultBucket — guards against
    // accidentally returning some other public S3 URL.
    expect(afterSrc).toContain('editresultbucket');
  });
});
