# 引き継ぎ資料: voice-image-edit / neuron-code-server デプロイ状況

**作成日**: 2026-05-24
**対象**: 次にこのリポジトリのデバッグを引き継ぐエンジニア
**目的**: 今日のセッションで「以前は動いていた code-server ログイン」が壊れた経緯を記録し、原因切り分けと復旧の出発点を渡す

---

## 1. 結論サマリ

- **症状**: ブラウザで `https://d1yrebil0jqv4h.cloudfront.net/` にアクセスすると、Cognito Hosted UI でログイン → `/oauth/callback` に redirect された後、Lambda が `400 Bad Request: state mismatch` を返してログインが完了しない。incognito ウィンドウでも同じ。
- **以前の状態**: Stage 1 (CloudFront + ALB + EC2 + Cognito) は完成済みで、ブラウザログイン → code-server アクセスまでは動作していた（task #32 で確認済）。
- **今日の介入で何が変わったか** (時系列、すべて私が触った):
  1. CloudFront Function の placeholder 未置換問題を CDK 側で恒久修正 (`String.replace` → `.split().join()`) — **本来動作には影響しない hotfix の追従**
  2. CloudFront Function の `crypto` builtin import 不在を修正 (`var crypto = require('crypto');` 追加) — **これは元々 LIVE function には反映されており、CDK template だけ追従させた**
  3. **HMAC secret をローテーション** — debug 中に secret が画面に出てしまったため。Secrets Manager / OAuth Lambda env / CloudFront Function inline の 3 箇所を新値で同期
  4. OAuth Lambda の `cf_oauth_state` cookie を `SameSite=Lax / Path=/oauth` → `SameSite=None / Path=/` に変更 → **state mismatch が解消しなかったので元に戻した** (現在の Lambda は元の `Lax / Path=/oauth`)
  5. OAuth Lambda の state mismatch 時に診断 console.warn を追加 — **これは残してある**
- **最も疑わしい原因**: HMAC secret ローテーション以前に最後にデプロイしたタイミングと、CDK 上の OAuth Lambda の `bundling` ハッシュが何らかの理由で齟齬を起こしている、または **CloudFront Function のキャッシュされたコードが古い HMAC で動いていて (1) と (3) の整合が崩れている** 可能性。直接的には state mismatch は cookie 不達なので、CloudFront Function の crypto エラーが解消されたあと、ブラウザに `cf_oauth_state` を渡す `/oauth/login` 応答 → Cognito top-level redirect → `/oauth/callback` の経路で cookie が消えている。
- **再開時の最初のアクション**: 下記 §6 「次にやるべきこと」を順番に。`SameSite=Lax` の状態で「以前の動作」を完全再現してから差分を最小化する。

---

## 2. 環境スナップショット (2026-05-24 時点)

### AWS リソース

| 項目 | 値 |
|------|-----|
| AWS Account | 776010787911 |
| AWS_PROFILE | `claude-code` (厳守) |
| Region (基盤) | sa-east-1 |
| Region (CloudFront API + Bedrock) | us-east-1 |
| CloudFront Distribution Id | E2DHD8VLHWML7W |
| CloudFront Domain | d1yrebil0jqv4h.cloudfront.net |
| CloudFront Function | sa-east-1neuron-code-servdViewerRequestFn9545B923 (LIVE は OK) |
| ALB | internal-neuron-Alb16-wlMggP6BvWRf-144504982.sa-east-1.elb.amazonaws.com |
| ALB SG | sg-094bc87f8dc5f61c7 |
| OAuth Lambda | neuron-code-server-alb-OAuthLambda063A5DDC-q5bMgig7cnZY |
| Cognito UserPool | sa-east-1_sBgULtcgT |
| Cognito Domain | neuron-code-server-ops.auth.sa-east-1.amazoncognito.com |
| HmacSecret ARN | arn:aws:secretsmanager:sa-east-1:776010787911:secret:HmacSessionSecret97211730-0Gfad2cTXRBh-83blj9 |

### Stage 1 / Stage 2 stack 状態

```
sa-east-1:
  neuron-code-server-efs        CREATE_COMPLETE
  neuron-code-server            CREATE_COMPLETE  (EC2)
  neuron-code-server-alb        CREATE_COMPLETE  (ALB + OAuth Lambda + Cognito)
  neuron-code-server-frontend   CREATE_COMPLETE  (CloudFront + Function)
  VoiceImageEditApiStack        CREATE_COMPLETE  (Stage 2 / /api/edit/* — Lambda VPC外)
```

### ブラウザログイン情報

- URL: https://d1yrebil0jqv4h.cloudfront.net/
- Email: admin@example.com
- Password: `v5VciCLzkGL3NnXr` (Cognito permanent password、私が今日生成)

### HMAC secret (3 箇所同期済)

- 値: `rUOkVia8mmLNAgqaecVwzjGNJdkzOz9v1qq7Ix69olOTFZhXYDEWdmDpJknhlETj` (64 chars)
- 反映場所:
  1. AWS Secrets Manager: `arn:aws:secretsmanager:sa-east-1:776010787911:secret:HmacSessionSecret97211730-0Gfad2cTXRBh-83blj9`
  2. OAuth Lambda env var `HMAC_SECRET`
  3. CloudFront Function (LIVE/DEV 両方) の `var HMAC_SECRET = '...'` inline
- **3 箇所一致を維持しないと cookie が verify できない**。Secrets Manager 値変更時は Lambda + CF Function 両方を再 deploy。

---

## 3. 既知のシステム構成

### 公開エントリポイント

```
[browser]
   |
   v
[CloudFront Distribution] (E2DHD8VLHWML7W)
   |   - viewer-request CloudFront Function (HMAC-SHA256 cf_session verify)
   |       - /oauth/* は HMAC bypass (cookie 発行経路だから)
   |       - それ以外は cookie 無し / 検証失敗で /oauth/login に 302
   |   - default behavior + /oauth/* 専用 behavior
   |   - origin: VPC Origin -> internal ALB :80
   |   - X-Origin-Verify ヘッダ (Secrets Manager 値) を origin に注入
   v
[Internal ALB :80]
   |   Listener Rules (priority 順):
   |     1: /oauth/* + X-Origin-Verify=<secret>     -> OAuth Lambda TG
   |     10..: /api/<name>/*                          -> 各 app TG
   |     1000: /*  + X-Origin-Verify=<secret>        -> code-server TG
   |     default: 403 fail-closed
   v
   ├─ OAuth Lambda Target Group (multi_value_headers.enabled=true)
   │     -> OAuth Lambda (handleLogin / handleCallback)
   │
   ├─ code-server Target Group (EC2 :8080)
   │
   └─ App Target Groups (/api/llm/* /api/whisper/* /api/avatar/* /api/vton/* /api/edit/*)
```

### Cookie 設計

| Cookie | 発行 | 用途 | 属性 |
|--------|------|------|------|
| `cf_oauth_state` | OAuth Lambda `/oauth/login` | CSRF nonce — `/oauth/callback` で query `state` と比較 | Path=/oauth; Max-Age=600; Secure; HttpOnly; **SameSite=Lax** (現状) |
| `cf_session` | OAuth Lambda `/oauth/callback` 成功時 | HMAC-SHA256 opaque session, body=`b64url({sub,email,exp})` | Path=/; Max-Age=3600; Secure; HttpOnly; SameSite=Lax |

### 認証フロー (本来あるべき動作)

```
1. browser GET /                                     (cookie なし)
2. CloudFront Function: cf_session 無し -> 302 Location: /oauth/login
3. browser GET /oauth/login                          (CF Function bypass)
4. CloudFront -> ALB -> OAuth Lambda handleLogin
   - nonce 生成 -> Set-Cookie: cf_oauth_state=<nonce>
   - 302 Location: https://<cognito-domain>/oauth2/authorize?...&state=<nonce>
5. browser -> Cognito Hosted UI -> ユーザがログイン
6. Cognito 302 Location: https://<cf-domain>/oauth/callback?code=<>&state=<nonce>
7. browser GET /oauth/callback?code=...&state=...    (Cookie: cf_oauth_state=<nonce>)
8. CloudFront -> ALB -> OAuth Lambda handleCallback
   - cookie の cf_oauth_state と query state を比較
   - 一致 -> Cognito /oauth2/token に code 交換 -> ID token 検証 -> cf_session 発行
   - Set-Cookie: cf_session=<body.sig>; Set-Cookie: cf_oauth_state=; Max-Age=0
   - 302 Location: /
9. browser GET /                                     (Cookie: cf_session)
10. CloudFront Function: HMAC verify OK -> origin pass
11. ALB catch-all -> code-server -> ユーザに UI
```

### state mismatch の発生位置

**ステップ 8** で `cookies.cf_oauth_state !== qs.state` の判定に失敗。今日の CloudWatch Logs では:

```json
{
  "cookieNames": ["cf_session"],
  "cookieStateLen": 0,
  "qsStateLen": 22,
  "cookieEq": false,
  "cookieHeaderPresent": true,
  "cookieHeaderLen": 177
}
```

つまり **`cf_oauth_state` cookie がブラウザから送信されていない**。`cf_session` だけが届いている (= 過去にログインに成功して払い出されたものの残骸)。`/oauth/login` の Set-Cookie 自体は curl で確認すると正常に出ている。

---

## 4. 今日の修正詳細 (差分)

### 4.1 setup/single-node/cdk/lib/cloudfront-frontend-stack.ts

```diff
- const cfFunctionCode = cfFunctionTemplate.replace('__HMAC_SECRET__', hmacSecretValue);
+ // String.replace は最初の 1 回だけ置換する仕様。template の line 14 にも
+ // コメントとして __HMAC_SECRET__ が出てくるので、global replace にしないと
+ // line 22 の var HMAC_SECRET 側が placeholder のまま残り、CF Function が
+ // ランタイムで 503 を返す。
+ const cfFunctionCode = cfFunctionTemplate.split('__HMAC_SECRET__').join(hmacSecretValue);
```

→ **次回 `cdk deploy neuron-code-server-frontend` で正しい secret が inline される**。

### 4.2 setup/single-node/cdk/cf-functions/viewer-request.template.js (untracked, .gitignore で `*.js` が無視)

LIVE Function には既に `var crypto = require('crypto');` が入っており、template も追従済。**runtime は `cloudfront-js-2.0` だが crypto は global builtin ではなく builtin module で、明示 require が必須。AWS docs:**
https://docs.aws.amazon.com/AmazonCloudFront/latest/DeveloperGuide/functions-javascript-runtime-20.html#writing-functions-javascript-features-builtin-modules-crypto-20

### 4.3 setup/single-node/cdk/lambda/oauth-callback/index.mjs (state mismatch の診断ログ追加のみ)

```diff
  if (cookies.cf_oauth_state !== qs.state) {
+   console.warn('state mismatch', JSON.stringify({
+     cookieNames: Object.keys(cookies),
+     cookieStateLen: cookies.cf_oauth_state ? cookies.cf_oauth_state.length : 0,
+     qsStateLen: qs.state.length,
+     cookieEq: cookies.cf_oauth_state === qs.state,
+     cookieHeaderPresent: cookieHeader.length > 0,
+     cookieHeaderLen: cookieHeader.length,
+   }));
    return albText(400, '400 Bad Request', 'state mismatch');
  }
```

`SameSite=None` への変更は **revert 済**で、現状は元の `SameSite=Lax / Path=/oauth`。

---

## 5. 既に試して **ハズレ** だった仮説

| # | 仮説 | 検証 | 結果 |
|---|------|------|------|
| H1 | CloudFront Function の HMAC placeholder 未置換 | LIVE function を get-function でダンプ | placeholder は real secret に置換済 (今は) |
| H2 | CloudFront Function の crypto builtin が global | Explore agent 経由で AWS docs 確認 | **誤情報。実際は require('crypto') 必須** |
| H3 | HMAC secret に trailing newline | DEV 版で発見 | LIVE は newline 無しで再 publish 済 |
| H4 | `SameSite=Lax / Path=/oauth` で Cognito top-level redirect 時に cookie が drop される | `SameSite=None / Path=/` に変更して試行 | **state mismatch 解消せず、revert** |
| H5 | 古い cf_session がブラウザに残ってループ | incognito で試行 | **incognito でも同じ症状** |

---

## 6. 次にやるべきこと (優先順)

### A. **以前に動いていた地点まで明示的に巻き戻す** (最優先)

このセッションで触った `cookie 設定 / HMAC ローテーション` を一旦置いて、**Stage 1 を一撃 deploy で再構築**して動作するか確認する手があります。

```bash
# 1. 全 stack destroy
bash <repo>/setup/single-node/scripts/deploy.sh \
  -r sa-east-1 --destroy --stack-name neuron-code-server

# 2. クリーン再 deploy
bash <repo>/setup/single-node/scripts/deploy.sh \
  -r sa-east-1 --use-spot --full --install-claude-code \
  --stack-name neuron-code-server \
  --operator-email admin@example.com \
  --operator-password 'v5VciCLzkGL3NnXr'
```

**これで動くかをまず確認する**。動けば、§4 の hotfix 群が原因ではない (= CDK が正しく synth できている) ことが証明される。

### B. 巻き戻しせずに、現状のまま追加デバッグするなら

ブラウザの Network タブで `/oauth/login` 応答の `set-cookie` ヘッダがブラウザに保存されているか確認する。Application タブ → Cookies → https://d1yrebil0jqv4h.cloudfront.net で `cf_oauth_state` が登録されているかを Cognito Hosted UI に飛ぶ前のタイミングでスクショ。

- もし **保存されている** → 問題は Cognito からの top-level redirect 時の cookie 送信側 (SameSite/Path)
- もし **保存されていない** → CloudFront が `Set-Cookie` を strip している (cache policy / origin response policy / behavior 設定)

### C. CloudFront のキャッシュ動作を疑う

`/oauth/*` の cache policy は `CACHING_DISABLED` だが、`Set-Cookie` を viewer に渡すには **Origin Request Policy** で `ALL_VIEWER` か、`Cookie Policy` を明示的に forward 設定する必要がある。現在の `originRequestPolicy: ALL_VIEWER` で本来 OK のはず → 確認:

```bash
AWS_PROFILE=claude-code aws cloudfront get-distribution-config \
  --region us-east-1 --id E2DHD8VLHWML7W \
  --query "DistributionConfig.CacheBehaviors.Items[?PathPattern=='/oauth/*']"
```

Response Headers Policy で `Set-Cookie` が drop されていないかも確認。

### D. ブラウザ側 Cookie store の確認手順

1. Chrome DevTools → Application → Storage → Cookies → https://d1yrebil0jqv4h.cloudfront.net
2. ログイン試行直後 (Cognito にリダイレクト *される前*) に cookie 一覧を見る
3. `cf_oauth_state` が無ければ、`Set-Cookie` がブラウザに届いていない。あれば、Cognito → /oauth/callback の redirect で送られていない (SameSite issue)

---

## 7. 触ってはいけないファイル / 注意点

- **HMAC secret の取り扱い**: AWS_PROFILE=claude-code 必須。値を terminal/log に echo しない。やむを得ず取得するなら `... > /tmp/sec.txt` のように file 経由で。最近の値: 上記参照。
- **直接 SSH でコマンド実行する**ことは禁止 (project rule)。EC2 操作は Task Runner 経由で。
- **コミットはユーザ明示依頼があるまでしない**。今日の差分 (`setup/single-node/cdk/lib/cloudfront-frontend-stack.ts`, `setup/single-node/cdk/lambda/oauth-callback/index.mjs`, `samples/voice-image-edit/README.md`) は uncommitted。
- **Co-Authored-By はコミットメッセージに入れない**。
- **企業名・個人名を新規ファイルに書かない**。

---

## 8. 関連リソース

- ADR-005 (Frontend = CloudFront + Cognito): `setup/single-node/docs/architecture/ADR-005-*` (探す)
- ADR-011 (ALB Lambda Target): 同上
- 既存ドキュメント:
  - `setup/single-node/docs/PROJECT_STATUS.md` (古い可能性あり、要更新)
  - `setup/single-node/docs/dlc-container-setup.md`
  - `samples/voice-image-edit/README.md`
  - `samples/voice-image-edit/app/README.md`
  - `samples/voice-image-edit/app/infra/deploy.sh` (Stage 2 deploy)
- Zenn 記事: https://zenn.dev/tosshi/articles/f3f678f4b6531c

---

## 9. クイックコマンド集

```bash
# CloudWatch Logs (state mismatch 詳細)
AWS_PROFILE=claude-code aws logs filter-log-events \
  --region sa-east-1 \
  --log-group-name "/aws/lambda/neuron-code-server-alb-OAuthLambda063A5DDC-q5bMgig7cnZY" \
  --start-time $(($(date +%s) * 1000 - 600000)) \
  --filter-pattern "state mismatch" \
  --query "events[].message" --output text

# Lambda code update (zip して反映)
cd <repo>/setup/single-node/cdk/lambda/oauth-callback
zip -q -r /tmp/oauth.zip index.mjs cookie.mjs package.json
AWS_PROFILE=claude-code aws lambda update-function-code \
  --region sa-east-1 \
  --function-name "neuron-code-server-alb-OAuthLambda063A5DDC-q5bMgig7cnZY" \
  --zip-file fileb:///tmp/oauth.zip

# CloudFront Function 確認
AWS_PROFILE=claude-code aws cloudfront get-function \
  --region us-east-1 \
  --name "sa-east-1neuron-code-servdViewerRequestFn9545B923" \
  --stage LIVE /tmp/live.js && head -35 /tmp/live.js

# /oauth/login 応答確認 (Set-Cookie ヘッダが出ているか)
curl -sS -D - -o /dev/null --max-redirs 0 https://d1yrebil0jqv4h.cloudfront.net/oauth/login

# HMAC 3 箇所一致確認
SM=$(AWS_PROFILE=claude-code aws secretsmanager get-secret-value --region sa-east-1 \
  --secret-id "arn:aws:secretsmanager:sa-east-1:776010787911:secret:HmacSessionSecret97211730-0Gfad2cTXRBh-83blj9" \
  --query SecretString --output text)
LE=$(AWS_PROFILE=claude-code aws lambda get-function-configuration --region sa-east-1 \
  --function-name "neuron-code-server-alb-OAuthLambda063A5DDC-q5bMgig7cnZY" \
  --query "Environment.Variables.HMAC_SECRET" --output text)
[ "$SM" = "$LE" ] && echo MATCH || echo MISMATCH
```

---

## 10. 「以前は動いていたのに」への正直な見解

ユーザの指摘は正当です。以下は私 (Claude) の推測です:

1. CloudFront Function の placeholder 未置換 (`__HMAC_SECRET__` の literal) は **以前から実は同じ問題があった可能性が高い**。`String.replace` は最初の 1 回だけ置換する仕様で、template 上に同 placeholder が 2 箇所 (line 14 のコメントと line 26 の var) あった。コメントが先にマッチしていたなら、HMAC verify は最初から壊れていた。
   - しかし以前ログインできていた = 当時の template にはコメント側の placeholder が無かった可能性
   - **どこかのコミットで template のコメントを編集し、そこに `__HMAC_SECRET__` を含めてしまった**のが導火線かもしれない (#74「viewer-request.template.js を復元」task が怪しい)
2. 一度 secret rotation を挟んだので、以前のブラウザに残っていた古い `cf_session` は今は invalid 扱い。これは正しい挙動。
3. state mismatch 自体は **CloudFront Function の crypto エラーが解消されてから** 出ている (= ユーザがログインに辿り着けるようになった結果として浮上した別問題)。なので「壊した」のではなく、「以前から (1) のバグで viewer-request 全体が爆発していて、ログイン以前で 503 になっていたが、CDK 由来でなく hotfix で隠れていただけ」かもしれない。

**確証はないので、§6.A の clean redeploy で「Stage 1 単体が一撃 deploy で動くこと」を確認するのが最短**。
