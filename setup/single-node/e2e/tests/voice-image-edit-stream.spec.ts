import { test, expect } from '@playwright/test';
import { CognitoLoginPage } from '../pages/CognitoLoginPage';

const TEST_EMAIL = process.env.TEST_USER_EMAIL!;
const TEST_PASSWORD = process.env.TEST_USER_PASSWORD!;

// Smoke for the P8 streaming path: ALB has a /stream/* listener rule that
// forwards to an IP-target Target Group on EC2:8080 (FastAPI/uvicorn).
// We do NOT touch the 4-stage pipeline here — that's P9. The point is to
// prove that:
//   1. /stream/health returns 200 through CloudFront after Cognito auth
//   2. /stream/echo emits SSE events that survive CF + ALB chunked transfer
//
// Cognito auth happens once for the whole spec via the page-level helper;
// page.request inherits the cookie jar so the unauthenticated GET also
// passes the cf_session HMAC viewer-request CF Function.
test.describe('voice-image-edit /stream/* (post-deploy)', () => {
  test.setTimeout(60_000);

  test('SSE roundtrip via /stream/health and /stream/echo', async ({ page, context }) => {
    await context.clearCookies();

    // Visit /edit just to drive the OAuth dance once. After Cognito the
    // cookie jar holds cf_session, which page.request reuses.
    await page.goto('/edit', { waitUntil: 'networkidle' });

    const cognito = new CognitoLoginPage(page);
    await page.waitForLoadState('networkidle');
    await cognito.expectVisible();
    await cognito.login(TEST_EMAIL, TEST_PASSWORD);

    await page.waitForURL((u) => !u.host.includes('amazoncognito.com'), { timeout: 30_000 });
    await page.waitForLoadState('networkidle');

    // /stream/health must come back 200 with the expected JSON shape.
    const healthRes = await page.request.get('/stream/health');
    expect(healthRes.status(), '/stream/health should be 200').toBe(200);
    const health = await healthRes.json();
    expect(health).toMatchObject({ status: 'ok', service: 'voice-image-edit-stream' });

    // /stream/echo must come back as text/event-stream and contain the
    // expected `event: tick` + `event: done` markers. We use a short
    // count + interval so the test stays well under the test timeout.
    const echoRes = await page.request.get(
      '/stream/echo?message=p8&count=3&interval_ms=50',
    );
    expect(echoRes.status(), '/stream/echo should be 200').toBe(200);
    const ct = echoRes.headers()['content-type'] ?? '';
    expect(ct, 'Content-Type should be text/event-stream').toContain('text/event-stream');

    const body = await echoRes.text();
    // 3 ticks + 1 done. SSE event lines are `event: tick` separated by
    // blank lines. We only assert presence and ordering here.
    const tickCount = (body.match(/^event: tick$/gm) ?? []).length;
    expect(tickCount, 'should receive 3 tick events').toBe(3);
    expect(body, 'should receive a final done event').toContain('event: done');
    // The data payload of the last tick must contain the message echoed
    // back. Regex stays loose to tolerate reordered JSON keys.
    expect(body).toMatch(/"message":"p8"/);
    // The done payload must report the count we asked for.
    expect(body).toMatch(/event: done\s*\ndata: \{[^}]*"sent":3[^}]*\}/);
  });
});
