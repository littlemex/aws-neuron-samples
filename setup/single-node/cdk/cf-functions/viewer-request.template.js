// CloudFront Function (JS_2_0) — viewer-request stage.
//
// Purpose:
//   Verify the cf_session opaque cookie issued by the OAuth Lambda
//   (lambda/oauth-callback/index.mjs via cookie.mjs:makeSessionCookie).
//   If the cookie is missing or invalid, redirect to /oauth/login so the
//   ALB OAuth Lambda Target can start a fresh Cognito Hosted UI flow.
//
// Cookie format (must mirror cookie.mjs exactly — see cookie-parity.test.mjs):
//   cf_session = <body>.<sig>
//     body = b64url(JSON.stringify({ sub, email, exp }))
//     sig  = b64url(HMAC-SHA256(secret, body))
//
// CDK synth replaces __HMAC_SECRET__ with the live AWS::SecretsManager
// value owned by AlbBackendStack (alb-backend-stack.ts:hmacSecret) and
// inlines it into the published function code (FunctionCode.fromInline).
//
// Bypass paths: /oauth/* must reach the ALB without HMAC gating because
// cf_session is *issued* there. Requiring it on /oauth/* would create
// an infinite redirect loop (see #20: ERR_TOO_MANY_REDIRECTS).
//
// crypto は CloudFront Functions の builtin module (JS_1_0 / JS_2_0 とも
// `require('crypto')` でロードする — global builtin ではない)。
// AWS docs:
// https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/functions-javascript-runtime-20.html#writing-functions-javascript-features-builtin-modules-crypto-20
// import 構文 (ESM) は parse error になるので使わないこと。
// runtime は KeyValueStore を使わない限り JS_2_0 を選ぶべき
// (CDK で `cloudfront.FunctionRuntime.JS_2_0`)。
var crypto = require('crypto');

var HMAC_SECRET = '__HMAC_SECRET__';

function b64url(s) {
  return s.replace(/=+$/, '').replace(/\+/g, '-').replace(/\//g, '_');
}

function b64urlDecodeToString(s) {
  var t = s.replace(/-/g, '+').replace(/_/g, '/');
  var pad = t.length % 4;
  if (pad === 2) t += '==';
  else if (pad === 3) t += '=';
  // Use Buffer.from() — JS_2_0 deprecated String.bytesFrom() and now
  // throws SyntaxError if called, which broke verifyCookie() and
  // produced ERR_TOO_MANY_REDIRECTS even with a valid cf_session.
  // https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/functions-javascript-runtime-20.html
  return Buffer.from(t, 'base64').toString('utf-8');
}

function verifyCookie(secret, cookie, nowSeconds) {
  if (typeof cookie !== 'string') return false;
  var dot = cookie.lastIndexOf('.');
  if (dot < 0) return false;
  var body = cookie.substring(0, dot);
  var sig = cookie.substring(dot + 1);

  var expected = b64url(
    crypto.createHmac('sha256', secret).update(body).digest('base64')
  );

  if (expected.length !== sig.length) return false;

  // Constant-time-ish compare. CloudFront Function has no
  // crypto.timingSafeEqual, so XOR-accumulate manually.
  var diff = 0;
  for (var i = 0; i < expected.length; i++) {
    diff |= expected.charCodeAt(i) ^ sig.charCodeAt(i);
  }
  if (diff !== 0) return false;

  // Pull `exp` via regex on the decoded JSON body. Cheap, and avoids
  // the JSON.parse cost which counts against the 1 ms CPU budget.
  var decoded;
  try {
    decoded = b64urlDecodeToString(body);
  } catch (e) {
    return false;
  }
  var m = decoded.match(/"exp"\s*:\s*(\d+)/);
  if (!m) return false;
  var exp = parseInt(m[1], 10);
  if (!exp || exp < nowSeconds) return false;
  return true;
}

function loginRedirect() {
  // OAuth Lambda's handleCallback always redirects to '/' on success
  // and does not honor a `next` parameter, so we keep the Function as
  // simple as possible. Add ?next= here only if handleLogin learns to
  // pass it through Cognito's state parameter.
  return {
    statusCode: 302,
    statusDescription: 'Found',
    headers: {
      location: { value: '/oauth/login' },
      'cache-control': { value: 'no-store' },
    },
  };
}

function handler(event) {
  var request = event.request;
  var uri = request.uri || '/';

  // /oauth/* must reach the ALB OAuth Lambda Target directly (login,
  // callback, logout) — cf_session is *issued* there, so HMAC-gating
  // it creates an infinite loop.
  if (uri.indexOf('/oauth/') === 0) {
    return request;
  }

  // request.cookies is { name: { value, attributes } } in JS_2_0.
  var cookies = request.cookies || {};
  var session = cookies['cf_session'];
  var cookieValue = session && session.value;
  if (!cookieValue) {
    return loginRedirect();
  }

  var now = Math.floor(Date.now() / 1000);
  if (!verifyCookie(HMAC_SECRET, cookieValue, now)) {
    return loginRedirect();
  }

  return request;
}
