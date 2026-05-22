// Cookie byte-parity tests.
//
// The Lambda issues a cf_session cookie via cookie.mjs:makeSessionCookie().
// The CloudFront Function (cf-functions/viewer-request.template.js) recomputes
// HMAC over the body half and string-compares against the signature half.
//
// Both runtimes must agree on:
//   - base64url encoding (no padding, '+' '/' rewritten to '-' '_')
//   - HMAC-SHA256 over the *exact* body bytes
//   - cookie format `<body>.<sig>` with the LAST '.' as the separator
//
// We don't actually run inside the CloudFront Function sandbox (no Node
// APIs there). What we do here is run the SAME verification algorithm
// the CF Function expresses, against cookies issued by the Lambda
// helper. If Lambda + CF Function disagree, this test fails.

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHmac, randomBytes } from 'node:crypto';
import {
  b64url,
  b64urlDecode,
  makeSessionCookie,
  verifySessionCookie,
} from '../lambda/oauth-callback/cookie.mjs';

// Node-side mirror of viewer-request.template.js, expressed without
// CloudFront-only APIs (String.bytesFrom). Keep this in lock-step with
// the .template.js file.
function cfVerify(secret, cookie, nowSeconds) {
  const dot = cookie.lastIndexOf('.');
  if (dot < 0) return false;
  const body = cookie.substring(0, dot);
  const sig = cookie.substring(dot + 1);
  const expected = createHmac('sha256', secret).update(body).digest('base64')
    .replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_');
  if (expected.length !== sig.length) return false;
  let diff = 0;
  for (let i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
  }
  if (diff !== 0) return false;
  // exp check (regex on plain JSON, same as CF Function)
  const decoded = b64urlDecode(body).toString();
  const m = decoded.match(/"exp"\s*:\s*(\d+)/);
  if (!m) return false;
  const exp = parseInt(m[1], 10);
  if (exp < nowSeconds) return false;
  return true;
}

const SECRET = randomBytes(32).toString('hex');
const CLAIMS = { sub: 'aaaa-bbbb-cccc-dddd', email: 'op@example.com' };

test('Lambda-issued cookie verifies via Node mirror of CF Function', () => {
  const c = makeSessionCookie(SECRET, CLAIMS, 60);
  assert.equal(cfVerify(SECRET, c, Math.floor(Date.now() / 1000)), true,
    'CF Function should accept a freshly issued cookie');
});

test('verifySessionCookie agrees with CF Function mirror', () => {
  const c = makeSessionCookie(SECRET, CLAIMS, 60);
  const a = verifySessionCookie(SECRET, c).ok;
  const b = cfVerify(SECRET, c, Math.floor(Date.now() / 1000));
  assert.equal(a, b);
  assert.equal(a, true);
});

test('Wrong secret -> reject', () => {
  const c = makeSessionCookie(SECRET, CLAIMS, 60);
  const wrong = randomBytes(32).toString('hex');
  assert.equal(cfVerify(wrong, c, Math.floor(Date.now() / 1000)), false);
  assert.equal(verifySessionCookie(wrong, c).ok, false);
});

test('Tampered body -> reject', () => {
  const c = makeSessionCookie(SECRET, CLAIMS, 60);
  // Flip one character of the body (first char). The signature stays
  // valid for the original body, so the recomputed sig will not match.
  const tampered = 'X' + c.substring(1);
  assert.equal(cfVerify(SECRET, tampered, Math.floor(Date.now() / 1000)), false);
});

test('Tampered signature -> reject', () => {
  const c = makeSessionCookie(SECRET, CLAIMS, 60);
  const tampered = c.substring(0, c.length - 1) +
    (c.endsWith('A') ? 'B' : 'A');
  assert.equal(cfVerify(SECRET, tampered, Math.floor(Date.now() / 1000)), false);
});

test('Missing dot -> reject', () => {
  assert.equal(cfVerify(SECRET, 'no-separator-here', 0), false);
  assert.equal(verifySessionCookie(SECRET, 'no-separator-here').ok, false);
});

test('Expired cookie -> reject', () => {
  const c = makeSessionCookie(SECRET, CLAIMS, -10); // exp 10s in the past
  const now = Math.floor(Date.now() / 1000);
  assert.equal(cfVerify(SECRET, c, now), false);
  assert.equal(verifySessionCookie(SECRET, c, now).ok, false);
});

test('verifySessionCookie returns claims on success', () => {
  const c = makeSessionCookie(SECRET, CLAIMS, 60);
  const r = verifySessionCookie(SECRET, c);
  assert.equal(r.ok, true);
  assert.equal(r.claims.sub, CLAIMS.sub);
  assert.equal(r.claims.email, CLAIMS.email);
  assert.ok(r.claims.exp > Math.floor(Date.now() / 1000));
});

test('b64url roundtrip', () => {
  const raw = Buffer.from([0xff, 0xee, 0xdd, 0x00, 0x01, 0x02, 0x03, 0x04]);
  const enc = b64url(raw);
  assert.ok(!/[+/=]/.test(enc), 'no +, /, or = in b64url output');
  const dec = b64urlDecode(enc);
  assert.deepEqual(Buffer.from(dec), raw);
});

test('Cookie format: exactly one body, one signature, dot-separated', () => {
  const c = makeSessionCookie(SECRET, CLAIMS, 60);
  // We use lastIndexOf so a stray '.' inside the JSON body is fine,
  // but for our payload (sub, email, exp -- all alphanumerics + '@')
  // there should be exactly one dot.
  const dots = (c.match(/\./g) || []).length;
  assert.equal(dots, 1, 'expected exactly one dot in cookie');
});
