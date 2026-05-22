import { test, expect } from '@playwright/test';

// These tests prove the CF Function fails closed: any request without
// a valid cf_session cookie is redirected to /oauth/login, never
// reaching the ALB. This is the structural guarantee we make to avoid
// DAST scanners flagging the deployment as an unauth web endpoint.
//
// We use page.request (an APIRequestContext bound to baseURL) so we
// can observe the response without auto-following redirects. A normal
// page.goto() would hide the 302 since browsers chase it.
test.describe('Auth boundary - fail closed', () => {
  test.beforeEach(async ({ context }) => {
    await context.clearCookies();
  });

  test('GET / without cookie redirects to /oauth/login', async ({ request }) => {
    const r = await request.get('/', { maxRedirects: 0 });
    expect(r.status()).toBe(302);
    const loc = r.headers()['location'];
    expect(loc, 'Location header should be present').toBeTruthy();
    expect(loc).toContain('/oauth/login');
  });

  test('GET /healthz without cookie redirects (no public endpoints)', async ({ request }) => {
    // Even a probe-shaped path must redirect. There is intentionally
    // no public unauth endpoint; the CF Function only exempts
    // /oauth/* (login + callback). Anything else: redirect.
    const r = await request.get('/healthz', { maxRedirects: 0 });
    expect(r.status()).toBe(302);
    expect(r.headers()['location']).toContain('/oauth/login');
  });

  test('tampered cookie still redirects', async ({ context, request }) => {
    // Inject a syntactically valid but signature-broken cookie. The CF
    // Function recomputes HMAC and constant-time compares; this must
    // fail.
    const cfHost = new URL(process.env.CF_BASE_URL!).host;
    await context.addCookies([
      {
        name: 'cf_session',
        value: 'eyJzdWIiOiJ4Iiwib2F1dGgiOiJ4IiwiZXhwIjo5OTk5OTk5OTk5fQ.AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        domain: cfHost,
        path: '/',
        httpOnly: true,
        secure: true,
        sameSite: 'Lax',
      },
    ]);
    const r = await request.get('/', { maxRedirects: 0 });
    expect(r.status()).toBe(302);
    expect(r.headers()['location']).toContain('/oauth/login');
  });

  test('malformed cookie (no dot) still redirects', async ({ context, request }) => {
    const cfHost = new URL(process.env.CF_BASE_URL!).host;
    await context.addCookies([
      {
        name: 'cf_session',
        value: 'no-separator-at-all',
        domain: cfHost,
        path: '/',
        httpOnly: true,
        secure: true,
        sameSite: 'Lax',
      },
    ]);
    const r = await request.get('/', { maxRedirects: 0 });
    expect(r.status()).toBe(302);
    expect(r.headers()['location']).toContain('/oauth/login');
  });

  test('/oauth/login itself does not redirect (would loop)', async ({ request }) => {
    // Sanity check: the exempt path returns Lambda's 302 to Cognito,
    // not the CF Function's 302 to /oauth/login. Both are 302s, but
    // the Location host differs.
    const r = await request.get('/oauth/login', { maxRedirects: 0 });
    expect(r.status()).toBe(302);
    const loc = r.headers()['location'] ?? '';
    expect(loc, 'should hand off to Cognito, not loop back to /oauth/login').toContain(
      'amazoncognito.com',
    );
  });
});
