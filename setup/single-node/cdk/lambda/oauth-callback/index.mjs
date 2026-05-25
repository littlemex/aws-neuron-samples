// OAuth callback Lambda (ADR-005 + ADR-011)
//
// Two routes are served via the internal ALB Lambda Target Group
// (NOT a Function URL or API Gateway — see ADR-011 for why):
//
//   GET /oauth/login
//     302 -> Cognito Hosted UI authorize endpoint
//     state cookie pinned to a random nonce so /oauth/callback can detect
//     mismatched re-entry / CSRF.
//
//   GET /oauth/callback?code=<code>&state=<state>
//     1. Validate state cookie matches `state` query param.
//     2. POST to Cognito /oauth2/token with grant_type=authorization_code.
//     3. Verify the returned ID token (signature via JWKS, exp/iss/aud).
//     4. Build an opaque session payload (sub, email, exp), HMAC-SHA256 sign
//        it with HMAC_SECRET (Secrets Manager), and Set-Cookie cf_session=...
//     5. 302 -> "/" (or the post-login target stashed in state cookie).
//
// EVENT SHAPE — ALB Lambda Target with multi-value headers enabled:
//   event.httpMethod                    e.g. "GET"
//   event.path                          e.g. "/oauth/login"
//   event.queryStringParameters         {code, state} (single-value)
//   event.multiValueHeaders             {cookie: ["..."], host: ["dXXX.cloudfront.net"], ...}
//   event.body, event.isBase64Encoded
//
// RESPONSE SHAPE — multiValueHeaders for multiple Set-Cookie:
//   { statusCode, statusDescription?, multiValueHeaders, body, isBase64Encoded? }
//
// The HMAC key is the SAME key the CloudFront Function verifies against.
// We deliberately keep the cookie payload tiny (<200 bytes) so the CF
// Function HMAC verify stays under the 1ms CPU budget by a wide margin.

import {
  CognitoIdentityProviderClient,
  DescribeUserPoolClientCommand,
  ListUserPoolClientsCommand,
} from '@aws-sdk/client-cognito-identity-provider';
import { randomBytes } from 'node:crypto';
import { b64url, b64urlDecode, makeSessionCookie } from './cookie.mjs';

const COGNITO_DOMAIN = process.env.COGNITO_DOMAIN; // e.g. xxx.auth.<region>.amazoncognito.com
const COGNITO_USER_POOL_ID = process.env.COGNITO_USER_POOL_ID;
const HMAC_SECRET = process.env.HMAC_SECRET; // shared with CF Function
const SESSION_TTL_SECONDS = parseInt(process.env.SESSION_TTL_SECONDS || '3600', 10);
const AWS_REGION = process.env.AWS_REGION || process.env.AWS_DEFAULT_REGION;

const cognitoIdp = new CognitoIdentityProviderClient({ region: AWS_REGION });

// Pick the operator UserPoolClient at init (cached for the container
// lifetime). The CDK stack creates exactly one UserPoolClient per pool;
// if more appear we take the first and log so the operator notices.
let cachedClientId = null;
async function getCognitoClientId() {
  if (cachedClientId) return cachedClientId;
  const out = await cognitoIdp.send(new ListUserPoolClientsCommand({
    UserPoolId: COGNITO_USER_POOL_ID,
    MaxResults: 5,
  }));
  const clients = out.UserPoolClients || [];
  if (clients.length === 0) throw new Error('No UserPoolClient on pool');
  if (clients.length > 1) {
    console.warn('Multiple UserPoolClients found; using first', clients.map((c) => c.ClientName));
  }
  cachedClientId = clients[0].ClientId;
  return cachedClientId;
}

let cachedClientSecret = null;
async function getCognitoClientSecret() {
  if (cachedClientSecret) return cachedClientSecret;
  const clientId = await getCognitoClientId();
  const out = await cognitoIdp.send(new DescribeUserPoolClientCommand({
    UserPoolId: COGNITO_USER_POOL_ID,
    ClientId: clientId,
  }));
  cachedClientSecret = out.UserPoolClient?.ClientSecret || null;
  return cachedClientSecret;
}

// Read a single header value, accepting both single-value `headers` and
// `multiValueHeaders` ALB shapes. ALB normalizes header names to lower
// case for both shapes, but we tolerate either casing for unit-test calls.
function getHeader(event, name) {
  const lower = name.toLowerCase();
  if (event.multiValueHeaders) {
    const v = event.multiValueHeaders[lower] || event.multiValueHeaders[name];
    if (Array.isArray(v) && v.length > 0) return v[0];
  }
  if (event.headers) {
    return event.headers[lower] || event.headers[name];
  }
  return undefined;
}

// Extract the CloudFront-facing host for redirect_uri. The ALB forwards
// the Host header from CloudFront, which is the distribution's domain
// (dXXXX.cloudfront.net) when ALL_VIEWER_EXCEPT_HOST_HEADER is used as
// the origin request policy. Fall back to env so unit tests can stub.
function getCloudFrontDomain(event) {
  return (
    getHeader(event, 'x-forwarded-host') ||
    getHeader(event, 'host') ||
    process.env.CLOUDFRONT_DOMAIN ||
    ''
  );
}

// Lazily fetched JWKS so cold-start cost is paid only once per Lambda
// container, not once per request.
let cachedJwks = null;
async function getJwks() {
  if (cachedJwks) return cachedJwks;
  const url = `https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}/.well-known/jwks.json`;
  const res = await fetch(url);
  if (!res.ok) throw new Error(`JWKS fetch failed: ${res.status}`);
  cachedJwks = await res.json();
  return cachedJwks;
}

// Minimal RSA-256 JWT verify against Cognito JWKS. We do this in the
// Lambda (NOT the CF Function) so the heavy crypto stays at OAuth
// callback time, paid once per login, never on hot path.
import { createPublicKey, createVerify } from 'node:crypto';

async function verifyIdToken(token, expectedAud) {
  const [h, p, s] = token.split('.');
  const header = JSON.parse(b64urlDecode(h).toString());
  const payload = JSON.parse(b64urlDecode(p).toString());
  const jwks = await getJwks();
  const jwk = jwks.keys.find((k) => k.kid === header.kid);
  if (!jwk) throw new Error('JWKS kid mismatch');
  const pubKey = createPublicKey({ key: jwk, format: 'jwk' });
  const verifier = createVerify('RSA-SHA256');
  verifier.update(`${h}.${p}`);
  const ok = verifier.verify(pubKey, b64urlDecode(s));
  if (!ok) throw new Error('JWT signature invalid');
  // Cognito ID token claims: iss, aud, token_use=id, exp
  const expectedIss = `https://cognito-idp.${AWS_REGION}.amazonaws.com/${COGNITO_USER_POOL_ID}`;
  if (payload.iss !== expectedIss) throw new Error('iss mismatch');
  if (payload.aud !== expectedAud) throw new Error('aud mismatch');
  if (payload.token_use !== 'id') throw new Error('token_use mismatch');
  const now = Math.floor(Date.now() / 1000);
  if (payload.exp < now) throw new Error('token expired');
  return payload;
}

function parseCookies(header) {
  const out = {};
  if (!header) return out;
  for (const part of header.split(';')) {
    const [k, ...v] = part.trim().split('=');
    if (k) out[k] = decodeURIComponent(v.join('='));
  }
  return out;
}

// ALB response builder. Always uses multiValueHeaders so multiple
// Set-Cookie can be returned in one response (the callback flow sets
// cf_session AND clears cf_oauth_state).
function albRedirect(location, setCookies = []) {
  return {
    statusCode: 302,
    statusDescription: '302 Found',
    multiValueHeaders: {
      location: [location],
      'cache-control': ['no-store'],
      'set-cookie': setCookies,
    },
    isBase64Encoded: false,
    body: '',
  };
}

function albText(statusCode, statusDescription, body) {
  return {
    statusCode,
    statusDescription,
    multiValueHeaders: {
      'content-type': ['text/plain; charset=utf-8'],
      'cache-control': ['no-store'],
    },
    isBase64Encoded: false,
    body,
  };
}

async function handleLogin(event) {
  const cloudfrontDomain = getCloudFrontDomain(event);
  const clientId = await getCognitoClientId();
  // CSRF nonce; the same value must come back via /oauth/callback?state=
  const nonce = b64url(randomBytes(16));
  const cognitoUrl = new URL(`https://${COGNITO_DOMAIN}/oauth2/authorize`);
  cognitoUrl.searchParams.set('client_id', clientId);
  cognitoUrl.searchParams.set('response_type', 'code');
  cognitoUrl.searchParams.set('scope', 'openid email');
  cognitoUrl.searchParams.set('redirect_uri', `https://${cloudfrontDomain}/oauth/callback`);
  cognitoUrl.searchParams.set('state', nonce);
  return albRedirect(cognitoUrl.toString(), [
    `cf_oauth_state=${nonce}; Path=/oauth; Max-Age=600; Secure; HttpOnly; SameSite=Lax`,
  ]);
}

// ALB Lambda Target with multi_value_headers.enabled=true delivers query
// string ONLY in event.multiValueQueryStringParameters (each value is an
// array). With the flag disabled, only event.queryStringParameters is
// populated. We tolerate both shapes so unit tests can stub either.
function getQueryParam(event, name) {
  const mv = event.multiValueQueryStringParameters;
  if (mv && Array.isArray(mv[name]) && mv[name].length > 0) return mv[name][0];
  const sv = event.queryStringParameters;
  if (sv && sv[name] != null) return sv[name];
  return undefined;
}

async function handleCallback(event) {
  const code = getQueryParam(event, 'code');
  const state = getQueryParam(event, 'state');
  const cookieHeader = getHeader(event, 'cookie') || '';
  const cookies = parseCookies(cookieHeader);
  if (!code || !state) return albText(400, '400 Bad Request', 'missing code/state');
  const qs = { code, state };
  if (cookies.cf_oauth_state !== qs.state) {
    // Diagnostic: state nonce は CSRF 防御目的で短命、ログ出力しても被害無し。
    // cookie 名一覧と長さのみ出して原因特定（cookie 未着 / 値ズレ / 期限切れ）を切り分ける。
    console.warn('state mismatch', JSON.stringify({
      cookieNames: Object.keys(cookies),
      cookieStateLen: cookies.cf_oauth_state ? cookies.cf_oauth_state.length : 0,
      qsStateLen: qs.state.length,
      cookieEq: cookies.cf_oauth_state === qs.state,
      cookieHeaderPresent: cookieHeader.length > 0,
      cookieHeaderLen: cookieHeader.length,
    }));
    return albText(400, '400 Bad Request', 'state mismatch');
  }

  const cloudfrontDomain = getCloudFrontDomain(event);
  const clientId = await getCognitoClientId();

  // Token exchange
  const tokenUrl = `https://${COGNITO_DOMAIN}/oauth2/token`;
  const body = new URLSearchParams({
    grant_type: 'authorization_code',
    client_id: clientId,
    code: qs.code,
    redirect_uri: `https://${cloudfrontDomain}/oauth/callback`,
  });
  const headers = { 'Content-Type': 'application/x-www-form-urlencoded' };
  const clientSecret = await getCognitoClientSecret();
  if (clientSecret) {
    const basic = Buffer.from(`${clientId}:${clientSecret}`).toString('base64');
    headers.Authorization = `Basic ${basic}`;
  }
  const tokRes = await fetch(tokenUrl, { method: 'POST', headers, body });
  if (!tokRes.ok) {
    const t = await tokRes.text();
    console.error('token exchange failed', tokRes.status, t);
    return albText(502, '502 Bad Gateway', 'token exchange failed');
  }
  const toks = await tokRes.json();
  if (!toks.id_token) return albText(502, '502 Bad Gateway', 'no id_token');

  const claims = await verifyIdToken(toks.id_token, clientId);
  const session = makeSessionCookie(HMAC_SECRET, claims, SESSION_TTL_SECONDS);

  return albRedirect('/', [
    `cf_session=${session}; Path=/; Max-Age=${SESSION_TTL_SECONDS}; Secure; HttpOnly; SameSite=Lax`,
    `cf_oauth_state=; Path=/oauth; Max-Age=0`,
  ]);
}

export const handler = async (event) => {
  // ALB shapes: event.path, event.httpMethod, event.queryStringParameters,
  // event.multiValueHeaders. We accept event.rawPath as a fallback so the
  // handler stays trivially testable without crafting a full ALB event.
  const path = event.path || event.rawPath || '/';
  try {
    if (path === '/oauth/login') return await handleLogin(event);
    if (path === '/oauth/callback') return await handleCallback(event);
    return albText(404, '404 Not Found', 'not found');
  } catch (err) {
    console.error('oauth lambda error', err);
    return albText(500, '500 Internal Server Error', 'internal error');
  }
};
