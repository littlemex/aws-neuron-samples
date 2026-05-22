# single-node E2E tests

CloudFront frontend stack の OAuth proxy 境界を Playwright で検証する。
デプロイ後の **smoke test** 兼 **regression guard** として走らせる想定。

## 何を検証しているか

二層構成。

### 1. Cookie byte-parity (deploy 不要)

`../cdk/test/cookie-parity.test.mjs`

Lambda が発行する `cf_session` cookie と、CloudFront Function が
検証で再計算する HMAC が **完全一致** することを Node 側で検証する。
両ランタイムは Node の `crypto` と CF Function の `crypto.createHmac`
というほぼ同一の実装を使うが、エッジケース（URL safe base64、`=` パディングの欠落、
最後の `.` での分割）でズレると無限ログインループになる。それを回避する。

```bash
cd ../cdk
node --test test/cookie-parity.test.mjs
```

10 ケース通れば OK。デプロイ前に CI で必ず通すこと。

### 2. Playwright journey (deploy 後)

`tests/oauth-flow.spec.ts` (happy path)
`tests/auth-bypass.spec.ts` (negative)

実際に CloudFront → Cognito Hosted UI → callback → code-server を
Headless Chromium で踏破する。

## 前提

- CloudFront frontend stack が deploy 済 (`bash deploy.sh ... --create-cloudfront-frontend`)
- Cognito User Pool に **operator user** が **permanent password** で作成済

operator user は Hosted UI に admin-create-user で発行された一時パスワードのまま
ログインすると force-change-password 画面に飛ばされる。E2E は対話せず突き抜ける必要があるため、
**必ず admin-set-user-password で permanent password に変えておく**。

```bash
USER_POOL_ID=$(aws cloudformation describe-stacks \
    --stack-name single-node-frontend --region <REGION> \
    --query 'Stacks[0].Outputs[?OutputKey==`UserPoolId`].OutputValue' --output text)

aws cognito-idp admin-create-user \
    --user-pool-id "$USER_POOL_ID" \
    --username op@example.com \
    --user-attributes Name=email,Value=op@example.com Name=email_verified,Value=true \
    --message-action SUPPRESS

aws cognito-idp admin-set-user-password \
    --user-pool-id "$USER_POOL_ID" \
    --username op@example.com \
    --password 'StrongTempPassword!1' \
    --permanent
```

## 環境変数

`tests/global-setup.ts` で必須チェック。未設定だと即 fail する（フォールバックなし）。

| Var | Source |
|-----|--------|
| `CF_BASE_URL` | CloudFront stack output `CloudFrontDomainName` を `https://` で囲む |
| `TEST_USER_EMAIL` | 上記の operator user |
| `TEST_USER_PASSWORD` | `admin-set-user-password` で設定した permanent password |

```bash
export CF_BASE_URL=https://$(aws cloudformation describe-stacks \
    --stack-name single-node-frontend --region <REGION> \
    --query 'Stacks[0].Outputs[?OutputKey==`CloudFrontDomainName`].OutputValue' --output text)
export TEST_USER_EMAIL=op@example.com
export TEST_USER_PASSWORD='StrongTempPassword!1'
```

## 実行

```bash
cd setup/single-node/e2e
npm install
npx playwright install chromium
npm test                # headless
npm run test:headed     # 目視確認したいとき
npm run report          # 失敗時の trace/screenshot を HTML で開く
```

成果物は `artifacts/` 以下:

- `artifacts/test-results/` — トレース、スクリーンショット、ビデオ（失敗時のみ retain）
- `artifacts/playwright-report/` — HTML レポート
- `artifacts/junit.xml` — CI 連携用

## トラブルシューティング

| 症状 | 原因 | 対処 |
|------|------|------|
| globalSetup で env var missing | `.env` を読んでない | `export` してから `npm test` |
| Cognito で `change.*password` 検知 | operator user が一時パスワード状態 | `admin-set-user-password --permanent` |
| `cf_session cookie should be set` で fail | callback Lambda が verify に失敗 | Lambda CloudWatch Logs を見る。`token_endpoint`/`jwks` の到達性を疑う |
| auth-bypass テストで 302 ではなく 200 | CF Function が紐付いていない or HMAC secret 取り違え | Distribution の Functions タブで viewer-request にアタッチされているか、KeyValueStore は使っていないので `__HMAC_SECRET__` 置換が走ったか確認 |
| `/oauth/login` が 502 | Lambda Function URL に IAM 認証付き OAC 経由で到達できていない | OriginAccessControl の signing が `SIGV4_ALWAYS` か、Lambda resource policy に CF Distribution からの `lambda:InvokeFunctionUrl` 許可があるか |

## 設計メモ

- **Page Object 化**: `pages/CognitoLoginPage.ts` と `pages/CodeServerPage.ts`。
  Cognito Hosted UI は data-testid を提供しないので `input[name=username]` 等の標準属性に賭けている。
  AWS が markup を変えたらこの 2 ファイルだけ直せばよい。
- **code-server の login 画面は突破しない**: code-server 自身のパスワードゲートは
  defense-in-depth であり OAuth 境界の検証範囲外。`expectReached()` は
  workbench か password 入力欄のどちらかが見えれば pass。
- **redirect URL を pin しない**: `host` が `amazoncognito.com` を含むかどうかだけで
  判定する。Cognito の domain 形式変更に対して脆くしないため。
- **negative test は `request` (APIRequestContext) を使う**: `page.goto()` は
  302 を自動追跡してしまうので、**fail-closed の証拠**としての 302 を直接
  observe する必要がある。
