// HMAC opaque session cookie helpers.
//
// The Lambda calls makeSessionCookie() once per /oauth/callback after
// it has verified the Cognito ID token. The CloudFront Function then
// runs verifySessionCookie() on every viewer request. Both sides must
// stay byte-compatible — the parity test in
// `cdk/test/cookie-parity.test.mjs` proves it.

import { createHmac, timingSafeEqual } from 'node:crypto';

export function b64url(buf) {
  return Buffer.from(buf).toString('base64')
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
}

export function b64urlDecode(s) {
  let pad = s.length % 4;
  if (pad) s += '===='.slice(0, 4 - pad);
  return Buffer.from(s.replace(/-/g, '+').replace(/_/g, '/'), 'base64');
}

function hmac(secret, payload) {
  return createHmac('sha256', secret).update(payload).digest();
}

export function makeSessionCookie(secret, claims, ttlSeconds) {
  const exp = Math.floor(Date.now() / 1000) + ttlSeconds;
  // Tiny payload: sub, email, exp. Anything bigger inflates the
  // CF Function HMAC-verify cost (which is bounded by 1ms CPU).
  const body = b64url(JSON.stringify({ sub: claims.sub, email: claims.email, exp }));
  const sig = b64url(hmac(secret, body));
  return `${body}.${sig}`;
}

export function verifySessionCookie(secret, cookie, nowSeconds = Math.floor(Date.now() / 1000)) {
  if (typeof cookie !== 'string') return { ok: false, reason: 'not-a-string' };
  const dot = cookie.lastIndexOf('.');
  if (dot < 0) return { ok: false, reason: 'no-separator' };
  const body = cookie.substring(0, dot);
  const sig = cookie.substring(dot + 1);
  const expected = b64url(hmac(secret, body));
  // timingSafeEqual requires equal-length inputs; pad/truncate by
  // converting to Buffer first. The lengths *should* always match
  // for legitimate signatures, so a length mismatch is itself a
  // verification failure.
  if (sig.length !== expected.length) return { ok: false, reason: 'sig-length' };
  const ok = timingSafeEqual(Buffer.from(sig), Buffer.from(expected));
  if (!ok) return { ok: false, reason: 'sig-mismatch' };
  let claims;
  try {
    claims = JSON.parse(b64urlDecode(body).toString());
  } catch {
    return { ok: false, reason: 'body-not-json' };
  }
  if (typeof claims.exp !== 'number') return { ok: false, reason: 'exp-missing' };
  if (claims.exp < nowSeconds) return { ok: false, reason: 'expired' };
  return { ok: true, claims };
}
