# single-node Trainium 検証基盤 実装状況

**最終更新**: 2026-05-22
**現フォーカス region**: sa-east-1
**最優先タスク**: 運営者ブラウザから CloudFront 経由で認証付き code-server に到達する経路の確立 (sa-east-1 完了 / `cdk deploy --full` で一撃 deploy 可能化)

判断の根拠は [ARCHITECTURE_DECISIONS.md](/Users/akazawt/.work/aws-neuron-samples/setup/single-node/ARCHITECTURE_DECISIONS.md)、設計の現状は [DESIGN.md](/Users/akazawt/.work/aws-neuron-samples/setup/single-node/DESIGN.md) を参照。

## 総合進捗

### Phase 別ステータス (sa-east-1)

| Phase | 内容 | 状態 | 主要 stack |
|-------|------|------|------------|
| 1 | EC2 (Trn2 Spot) + EFS persistence | 完了 | `storeai-validation-sae1`, `storeai-validation-sae1-efs` |
| 2 | AlbBackendStack (internal ALB + 5 TG + OAuth Lambda Lambda Target) | 完了 | `storeai-validation-sae1-alb` |
| 3 | CognitoOperatorStack (UserPool + Hosted UI domain) | 完了 | `storeai-validation-sae1-cognito` |
| 4 | CloudFrontFrontendStack (CF Function HMAC + VPC Origin + UserPoolClient) | 完了 | `storeai-validation-sae1-frontend` |
| 5 | app routing (`/api/llm/*` `/api/vton/*` 等) | 未着手 | (別 phase) |

### E2E 検証結果

**2026-05-22 sa-east-1**: ブラウザ → CloudFront → Cognito → code-server の到達経路が確立。

7 step E2E (curl ベース、`/tmp/oauth_e2e.py`) 全 pass:

1. `GET /` (no cookie) → 302 `/oauth/login` (CF Function HMAC fail)
2. `GET /oauth/login` → 302 Cognito `/oauth2/authorize`
3. Cognito `/oauth2/authorize` → 302 `/login`
4. `GET /login` → 200 sign-in form + `_csrf` token
5. `POST /login` (signin) → 302 `/oauth/callback?code=&state=`
6. `GET /oauth/callback` → 302 `/` + `Set-Cookie: cf_session=...`
7. `GET /` (with cf_session) → 200 (nginx/code-server に到達、CF Function 通過)

distribution: `d3rehj1mrwesra.cloudfront.net`

## 完了した作業

### Phase 1-4 sa-east-1 deploy + E2E 成功までの主要修正

- ALB Lambda Target は query を `event.multiValueQueryStringParameters` にしか配らない (`event.queryStringParameters` は undefined)。`getQueryParam(event, name)` ヘルパーを追加し OAuth callback を両 shape 対応に
- CloudFront Function 2.0 は Cookie ヘッダを `request.cookies` (構造化) に置く。`request.headers['cookie']` は空。先に `request.cookies['cf_session'].value` を読んで fallback で headers を見る二段構えに
- CloudFront Function 2.0 で `String.bytesFrom()` は deprecated → `Buffer.from(b64, 'base64')` に統一
- `Buffer.from(...).match()` は TypeError → `.toString('utf-8')` してから regex extract
- `/oauth/*` behavior は `ALL_VIEWER` を使う (`ALL_VIEWER_EXCEPT_HOST_HEADER` だと Host が ALB DNS に書き換わり Cognito redirect_uri が壊れる)
- **default behavior (code-server) も `ALL_VIEWER`** が必須。`ALL_VIEWER_EXCEPT_HOST_HEADER` だと code-server の WebSocket origin check (`Host` vs `Origin` 一致) が落ちて 403 → ブラウザに `WebSocket close 1006` (ADR-012 #5)
- code-server `auth: password` だと WebSocket upgrade も password challenge にかかって 403 になる。CloudFront Function (cf_session HMAC) で認証済みなので `auth: none` に切り替え (`/home/coder/.config/code-server/config.yaml`)

詳細は [ARCHITECTURE_DECISIONS.md ADR-012](/Users/akazawt/.work/aws-neuron-samples/setup/single-node/ARCHITECTURE_DECISIONS.md) を参照。

### push 整理 (2026-05-22)

- VS Code 拡張 install から `saoudrizwan.claude-dev` (Cline) と `AmazonWebServices.amazon-q-vscode` を削除 (`tasks/code-server-setup.json` task `15-install-vscode-extensions`)。AWS Toolkit のみ残す
- ADR-013: `cdk deploy` 一撃で Cognito operator user を bootstrap する経路を実装
  - `cdk/lib/cognito-operator-stack.ts` に Custom Resource 経由の AdminCreateUser + AdminSetUserPassword(Permanent=true) を追加
  - `cdk/lambda/cognito-bootstrap-user/index.mjs` (新規 Lambda、UsernameExistsException を idempotent 扱い)
  - `scripts/deploy.sh` に `--operator-email` / `--operator-password` / `--operator-password-secret-arn` / `--full` を追加
  - password は Secrets Manager に書き込み、CDK には Secret ARN だけを context で渡すので CFN template / cdk.out / drift detection に plaintext が残らない
  - `--full` で `--create-efs --create-alb-backend --create-cognito --create-cloudfront-frontend` を一括有効化

### CDK / 実装ファイル

| パス | 状態 |
|------|------|
| `cdk/lib/torch-neuron-stack.ts` | 不変 |
| `cdk/lib/efs-persistence-stack.ts` | 不変 |
| `cdk/lib/alb-backend-stack.ts` | OAuth Lambda Lambda Target 追加 (ADR-011) |
| `cdk/lambda/oauth-callback/index.mjs` | `multi_value_headers` 対応で `getQueryParam` 追加 |
| `cdk/lib/cognito-operator-stack.ts` | 不変 |
| `cdk/lib/cloudfront-frontend-stack.ts` | `/oauth/*` を `ALL_VIEWER` に変更 |
| `cdk/cf-functions/viewer-request.template.js` | `request.cookies` 優先 + Buffer.from + toString パターンに修正 |
| `cdk/lib/cognito-operator-stack.ts` | ADR-013: operator bootstrap Custom Resource を追加 |
| `cdk/lambda/cognito-bootstrap-user/index.mjs` | 新規: AdminCreateUser + AdminSetUserPassword Lambda |
| `tasks/code-server-setup.json` | claude-dev / amazon-q-vscode の install 行を削除 |
| `scripts/deploy.sh` | `--operator-email` / `--operator-password` / `--full` を追加 |

## 未確定事項 / 次のステップ

### 高優先

1. **Phase 5 app routing 着手**: `/api/llm/*` `/api/vton/*` `/api/whisper/*` `/api/avatar/*` の ALB listener rule + container 起動。code-server 到達 (Phase 4) は完了したので着手可能
2. **ap-southeast-4 への横展開**: ADR-011 で OAuth Lambda の region 制約 (Function URL 未対応) は解消。sa-east-1 で得た 4 つの Gotcha (ADR-012) を smoke test に組み込んだ上で再開可能
3. **CDK 上の deploy.sh per-phase isolation 改善**: 現状 `--create-cloudfront-frontend` 単独再 deploy では `albEc2InstanceId` / `albEc2SecurityGroupId` を再注入する必要があり、stub を入れると AlbBackendStack が rebuild される。target stack だけ更新できる経路を整備

### 中優先

4. **CF Function deploy が CDK の VpcOrigin replacement で失敗する事象の恒久対策**: VpcOrigin が distribution に attach されている間は更新失敗。今回は `aws cloudfront update-function` で直接 LIVE を差し替えて回避したが、CDK 経路の改修が必要 (logical id を分離するなど)

### 低優先

5. WAF / IP allowlist の段階導入 (ADR-009 で validation phase は WAF off 方針、本格運用で再検討)
6. Trn2.48xlarge 大規模検証 (us-east-2 Capacity Block) — 別タスク

## チーム体制

| 役割 | 担当 |
|------|------|
| 設計 / ADR / E2E 検証 | Claude (本セッション) |
| 運用 (Cognito user 追加 / EC2 Spot 補充) | 運営者 (admin-create-user 経路) |

## 参考ドキュメント

- [ARCHITECTURE_DECISIONS.md](/Users/akazawt/.work/aws-neuron-samples/setup/single-node/ARCHITECTURE_DECISIONS.md): ADR-001〜ADR-012
- [DESIGN.md](/Users/akazawt/.work/aws-neuron-samples/setup/single-node/DESIGN.md): 全体アーキテクチャ図と Phase 分割
- E2E test: `/tmp/oauth_e2e.py`
