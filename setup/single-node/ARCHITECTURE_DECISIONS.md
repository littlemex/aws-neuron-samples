# Architecture Decision Records — Trainium 検証基盤

このファイルは「**今こうなっている**」(DESIGN.md) ではなく、「**なぜそうなっているか / なぜそれ以外を選ばなかったか**」を残すためのドキュメントです。後から実装に触る人 (将来の自分を含む) が次のような疑問を持ったときの一次資料として書いています。

> 「ALB を internet-facing にすればドメイン要らないのでは?」
> 「Verified Access の方が標準的じゃないの?」
> 「Cognito JWT を CloudFront Function で検証すればよくない?」
> 「SSM port forward で十分なんじゃ?」

これらは検討した上で却下しています。理由は以下の通りです。

---

## ADR-001: ドメイン持ち込み禁止 (合意)

**Status**: Accepted (2026-05-22)

**Context**
- 検証基盤は社内 demo / 検証用途。永続的な公開ドメインを発行する運用負荷を持ちたくない
- Route 53 hosted zone を新設すると、ライフサイクル管理 (delegation 設定 / TTL / 廃止時の dangling DNS) が責務に増える
- リージョン切替を頻繁に行うため、ドメインを Region に紐付ける運用 (例 `validation.us-east-2.example.com`) は破綻しやすい

**Decision**
ACM cert を要求する手段は **すべて却下する**。クライアント側 (ブラウザ) に提示する TLS 証明書は AWS マネージド (`*.cloudfront.net`, `*.amazoncognito.com`, `vpce-...vpce.amazonaws.com` 等) のみを使う。

**Consequences**
- 後述の ADR-002 / ADR-003 / ADR-004 で「cert 必須の手段」を機械的に却下できる
- フロントエンドの URL は `dXXXX.cloudfront.net` 固定。これが嫌な場合は本 ADR を覆す必要がある (ACM 発行 + Route 53 を持ち込む)

---

## ADR-002: Verified Access (VA) を採用しない

**Status**: Rejected (2026-05-22)

**Context**
当初は VA endpoint type=load-balancer + Cognito OIDC trust provider で「ブラウザで Hosted UI 認証 → ALB に到達」を実現する設計で `cdk/lib/verified-access-stack.ts` を実装した (ap-southeast-4 で synth 検証まで完了)。

**Why we rejected it**
`AWS::EC2::VerifiedAccessEndpoint` (type=load-balancer) には以下が **必須パラメータ**:

- `applicationDomain` (FQDN)
- `domainCertificateArn` (ACM cert)

`applicationDomain` は VA 自身が auto-assign する `vae-xxx.elb.<region>.vpce.amazonaws.com` とは別物で、CloudFront / ブラウザが Host ヘッダで送るドメインに対する cert を VA が serve するために要求される。`*.cloudfront.net` のような AWS マネージド cert で代替する API は存在しない。

これは ADR-001 (ドメイン持ち込み禁止) と直接衝突する。

**Alternatives considered**
- 「Public な ACM 発行 + DNS 検証なし」 → ACM は発行時点で domain ownership 検証 (DNS or Email) を要求するため不可
- 「Private CA (PCA) で cert 発行」 → PCA 月 $400 で検証用途として過剰、CloudFront origin として使う場合は public CA chain が要求されるためそもそも噛み合わない
- 「self-signed cert を ACM import」 → 上記同様、CloudFront origin としては public chain の検証に通らない

**Consequences**
- `cdk/lib/verified-access-stack.ts` は削除する
- VA 案で生まれた副産物 (Cognito UserPool の admin-create-user 設計、Cedar 風の IP allowlist) は ADR-005 採用案の Cognito 設計に流用する

---

## ADR-003: ALB の HTTPS listener (cert 必須) を採用しない

**Status**: Rejected (2026-05-22)

**Context**
ALB に直接 HTTPS listener + ACM cert を載せれば、CloudFront origin として `https://...` で繋げる。

**Why we rejected it**
- HTTPS listener は ACM cert が必須 → ADR-001 違反
- ALB を internet-facing にすればクライアントから直接届くが、それは DAST UnauthWebEndpoint の検出を確実に踏むので絶対に避ける

**Decision**
ALB は **internal scheme** + **HTTP listener (port 80)** のみ。CloudFront から ALB への区間は `VPC Origin` (2024-11 GA) を使い、CloudFront 内部経路の HTTP で繋ぐ。CloudFront 側で TLS 終端しているため、CloudFront → ALB 区間が HTTP でも viewer 経路は HTTPS。

VPC Origin が選択肢に入ることで「ALB に cert を載せなくて済む」のがこの ADR を成立させる鍵。VPC Origin GA (2024-11) 以前は internal ALB を CloudFront origin にする手段がなかった。

---

## ADR-004: Lambda@Edge を採用しない

**Status**: Rejected (2026-05-22)

**Context**
CloudFront viewer-request で OAuth dance / Cookie 検証をやらせる典型パターンとして Lambda@Edge がある。

**Why we rejected it**
- Lambda@Edge は **us-east-1 強制**。バックエンド (ap-southeast-4 / us-east-2) と分離するためクロスリージョン参照 (`crossRegionReferences: true`) が必須となり、CDK stack 構成が複雑化する
- Lambda@Edge は version-pinned で deploy 反映に数分のラグがあり、検証フェーズの繰り返し作業に向かない
- 同じことが CloudFront Functions で 1ms 制約を守れば実現できる (ADR-005 参照)

**Decision**
全リソースをバックエンドリージョンに集約する。CloudFront Distribution それ自体はリージョンレス (global) なので、ap-southeast-4 / us-east-2 の Stack に含めても問題ない。

---

## ADR-005: 認証は CloudFront default cert + Cognito Hosted UI + HMAC opaque session cookie

**Status**: Accepted (2026-05-22)

**Context**
ADR-001〜004 で却下されたものを除外すると、要件 (ドメイン不要 + リージョン跨ぎなし + 未認証エンドポイント検出を踏まない + ブラウザだけで code-server に届く) を満たす経路は **CloudFront 層で認証を完結させる** しか残らない。

**Decision**

```
[ブラウザ]
   |
   | HTTPS https://dXXXX.cloudfront.net (default cert *.cloudfront.net)
   v
[CloudFront Distribution]
   |
   |  Viewer-Request: CloudFront Function
   |    cf_session Cookie の HMAC 署名を検証
   |    無効/欠如 → 302 /oauth/login
   |
   |  All behaviors (default / /oauth/*):
   |    Origin = VPC Origin → 内部 ALB :80 (HTTP)
   |    Custom Origin Header: X-Origin-Verify: <secret>
   v
[内部 ALB]
   listener rule:
     /oauth/*  + X-Origin-Verify 一致 → TG (Lambda)        [ADR-011]
     /api/*    + X-Origin-Verify 一致 → TG :8090 / :8081 / ...
     /*        + X-Origin-Verify 一致 → TG :80 (code-server)
   default action: 403 fail-closed
   |
   v
[OAuth Lambda] (ALB Lambda Target、インターネット露出なし)
   Cognito Hosted UI (*.amazoncognito.com) と OAuth code 交換
   成功時に HMAC 署名付き opaque session cookie を Set-Cookie
```

OAuth Lambda は ALB の Lambda Target Group として expose する。Function URL や API Gateway を **使わない**。これにより OAuth エンドポイント自体がインターネットから DNS resolve できなくなる (ADR-011 で詳述)。

**設計の核**: Cookie の検証ロジックを **HMAC-SHA256 にすることで CloudFront Function の 1ms 制約に余裕を持って収める**。RSA-256 JWT 直接検証 (Cognito ID token そのもの) は 0.3〜0.5ms の綱渡りで、トークンサイズ次第で 503 を返す事故の可能性があった (Architect 2 案)。HMAC は ~0.05ms で 20 倍の余裕がある。

代わりに「Cognito ID token そのものを検証して通す」という標準パスは捨てている。OAuth dance の出口で Lambda が一度だけ ID token を verify し、自前で発行した opaque session cookie に置き換える。CloudFront Function は HMAC のみ。これは「OAuth proxy」と呼ばれる古典的なパターンで、`oauth2-proxy` などが同じ構造を取る。

**Why HMAC over JWT verification at edge**

| 観点 | RSA-256 JWT 検証 | HMAC opaque cookie |
|---|---|---|
| CF Function 実行時間 | 0.3〜0.5ms (1ms 制約に余裕なし) | ~0.05ms (20 倍余裕) |
| 鍵配布 | Cognito JWKS を CF Function に静的埋め込み (UserPool 再作成で破綻) | HMAC 鍵を Secrets Manager → 自前管理 (rotation 容易) |
| クレーム再利用 | Cognito ID token のクレームをそのまま使える | Lambda が必要クレームだけ抽出して cookie に書き込む |
| 監査 | JWT は subject / aud / iss が標準 | opaque cookie の中身は自前 schema、ログ設計が必要 |

検証用途では「鍵管理の単純さ」「1ms 制約の確実な遵守」が JWT のクレーム再利用性を上回る。

**Consequences**
- HMAC 鍵の rotation には CF Function の再 deploy が必要 (~1 分の伝播)
- CloudFront Function code に Secrets Manager の値を CDK build 時に埋め込む。secret rotation hooks で自動再 deploy するか、手動 rotation で十分か、運用フェーズで決める (現状は手動 rotation 想定)
- Lambda が OAuth dance のみ担当する小さなコンポーネントになる (~100 行)。**ALB Lambda Target で expose** し (ADR-011)、CloudFront default cache disabled

---

## ADR-006: code-server へのアクセスを SSM port forward 単独に絞らない

**Status**: Rejected (2026-05-22) — SSM 単独案

**Context**
最初の防御策として「SSM Session Manager port forward でのみ code-server に到達」案を検討した (Architect 1 案)。EC2 SG ingress ゼロ + IAM 認証で、未認証エンドポイント検出のリスクは構造的に消える。

**Why we rejected it as the sole option**
- 運営者は AWS CLI + Session Manager plugin のセットアップが必要 (社内であれば成立するが、外部解説者がいる場合のフリクションが大きい)
- 「複数オペレーターが同じ URL をブラウザで開いて画面共有しながらデモを進める」というユースケース要求があった (この要求が後から判明したため当初の案では満たせなかった)
- code-server の URL がオペレーターごとに `localhost:808x` になり、URL を共有できない

**Decision**
SSM port forward は **bypass 経路 (障害時のフォールバック)** として温存する。`NeuronCodeServerStack` の SG ingress ゼロ + SSMConnectCommand Output は変更しない。CloudFront 経路がダウンしたときの非常口として残す。

メイン経路は ADR-005 (CloudFront 経由)。

---

## ADR-007: ALB に code-server target group を残す (案 C ハイブリッドからの変更点)

**Status**: Accepted (2026-05-22)

**Context**
3-architect 検討で案 C (ハイブリッド) は「ALB は API 専用に純化、code-server は SSM 経路のみ」を提案していた。

**Why we changed**
ADR-006 で SSM 単独を却下したため、ブラウザ経由で code-server に届く必要がある。`AlbBackendStack` の code-server catch-all rule (priority 1000) を **そのまま維持**して、CloudFront → ALB → code-server :80 の経路を成立させる。

**Consequences**
- ALB SG inbound には CloudFront managed prefix list (`com.amazonaws.global.cloudfront.origin-facing`) を追加する
- ALB listener default action は 403 fail-closed のまま (catch-all rule は priority 1000 で「path=/* + X-Origin-Verify match」、これにマッチしない直叩きは 403)
- code-server catch-all rule にも X-Origin-Verify ヘッダ条件を追加する必要がある (現状 path のみで match している)。これがないと CloudFront を通らない直叩きが catch-all rule にヒットして code-server に到達してしまう

---

## ADR-008: DAST UnauthWebEndpoint 検出防御層

**Status**: Accepted (2026-05-22)

**Context**
過去に同種アカウントで DAST UnauthWebEndpoint 検出による外部スキャナ警告を切られた経緯がある。再発を避けるため防御層を多重化する。

**Decision** — 6 段の防御層

| # | 層 | 機構 | 防ぐもの |
|---|---|---|---|
| 1 | CloudFront WAF | managed rules + IP allowlist (オプション) + rate limit | DAST スキャナ / bot / DDoS |
| 2 | CloudFront Function (HMAC verify) | session cookie 不在 → 302 /oauth/login | 未認証ユーザーが origin に届かない |
| 3 | Cognito Hosted UI (`*.amazoncognito.com`) | OAuth dance 認証 | パスワード認証 + (opt) MFA |
| 4 | ALB SG | inbound = CloudFront managed prefix list のみ | CloudFront を通らない直叩き不可 |
| 5 | ALB listener rule | X-Origin-Verify ヘッダ一致必須 (CloudFront が Custom Origin Header で注入) | CloudFront 経路の証明 |
| 6 | ALB listener default | 403 fail-closed | rule 不一致を全拒否 |

**DAST スキャナの観点**
- ALB は internal scheme で public DNS / IP なし → スキャナが直接届かない
- **OAuth Lambda も ALB Lambda Target でしか expose しない** ので Function URL / API Gateway 経由の `*.lambda-url.<region>.on.aws` / `*.execute-api.<region>.amazonaws.com` のような **インターネットから DNS resolve できる エンドポイントが一切存在しない** (ADR-011)
- CloudFront URL `dXXXX.cloudfront.net` は public だが、`/` および `/api/*` は層 #2 (HMAC cookie 不在) で `/oauth/login` への 302
- `/oauth/login` への到達は許可するが、これは Cognito Hosted UI (`*.amazoncognito.com`、AWS マネージド) へのリダイレクトのみ (認証メカニズム自体)
- 「未認証で web UI が露出している」検出要件は **満たさない** ので切られない (はず)

WAF IP allowlist を **入れる** か **入れないか** は ADR-009 で決める。

---

## ADR-009: WAF IP allowlist の有無

**Status**: Pending

**Context**
ADR-008 の防御層 #1 として CloudFront WAF を立てる。managed rules は確定として、IP allowlist (運営者拠点の CIDR のみ許可) を入れるかどうかが決まっていない。

**Trade-off**
- **入れる場合**: DAST が `/oauth/login` にすら届かなくなり、未認証エンドポイント検出に対する防御がさらに堅くなる。代償として運営者の出張先・自宅 IP の追加運用が発生する。CIDR を operator-ip.json 等で管理し PR で更新する形が現実的
- **入れない場合**: 運営者がどこからでも繋げる利便性。検出回避は層 #2-#6 で防げているはずだが、防御層が 1 段薄くなる

**Decision** — 検証フェーズでは **入れない**。ADR-008 の防御層 #2-#6 だけで未認証エンドポイント検出をクリアできる前提で進める。本番デモ前に DAST 相当のスキャンを自分で回し、検出されないことを確認した上で、必要なら本番では IP allowlist を追加する。

---

## ADR-011: OAuth Lambda は ALB Lambda Target で expose する (Function URL / API Gateway を採用しない)

**Status**: Accepted (2026-05-22)

**Context**
ADR-005 で OAuth dance を担う Lambda の expose 方法として当初 Lambda Function URL + OriginAccessControl (SIGV4_ALWAYS) を採用していた。これを ap-southeast-4 で deploy しようとしたところ、`AWS::Lambda::Url` が CFN リソースタイプとして未サポートで弾かれた (`describe-type` で `TypeNotFoundException`)。代替として API Gateway HTTP API + Lambda 統合を検討したが、根本的な問題があることに気づいた。

**The DAST observability problem**

Function URL も API Gateway も、AWS が払い出す **インターネットから DNS resolve 可能なホスト名** を持つ:

| 案 | 公開ホスト名 | DAST スキャナから見た時 |
|---|---|---|
| Lambda Function URL + OAC | `<id>.lambda-url.<region>.on.aws` | resolve できる → 403 を返す → **「認証必須の web エンドポイントが公開されている」と検出される** |
| API Gateway Regional + IAM | `<id>.execute-api.<region>.amazonaws.com` | 同上 |

OAC や IAM auth で「CloudFront 以外からの呼び出しは 403」にすることは可能だが、エンドポイント自体がインターネットから観測可能な以上、**未認証 web エンドポイント検出 (UnauthWebEndpoint) のシグネチャを構造的に踏む**。これは ADR-008 の防御目標 (「DAST に切られない構造」) に反する。

**Decision**
OAuth Lambda を **internal ALB の Lambda Target Group として ALB の listener rule 経由で expose する**。Function URL も API Gateway も使わない。

```
[CloudFront Distribution]
   |
   |  Behavior /oauth/* → Origin = VPC Origin → 内部 ALB :80
   |  Custom Origin Header: X-Origin-Verify: <secret>
   v
[内部 ALB]
   listener rule:
     path=/oauth/* + X-Origin-Verify match → TG (Lambda)
   default action: 403 fail-closed
   |
   v
[OAuth Lambda]   ← ALB が直接 invoke。Function URL も API Gateway もない
```

**Why this is structurally better**
- OAuth Lambda がインターネットから DNS resolve できるホスト名を **持たない** (ALB は internal scheme + zero ingress except CloudFront prefix list)
- CloudFront origin が ALB 1 本に集約され、CDK 構成が単純化される
- ALB Lambda Target は **Function URL のような region 制約がない** ので sa-east-1 / ap-southeast-4 / その他検証 region で同じコードが deploy できる
- 既存の X-Origin-Verify header check (ADR-008 #5) を OAuth ルートにもそのまま適用できる

**Trade-offs**
- ALB Lambda Target は per-request invoke コストが Function URL 比でやや高い (~ms オーダー、機能には影響なし)
- ALB → Lambda の event format は Function URL の `event.rawPath` 形式とは異なる (`event.path`, `event.queryStringParameters`, `event.headers`)。Lambda コード側で両方のシェイプを許容するか、ALB shape にだけ合わせる
- ALB Target Group + permission (`elasticloadbalancing:RegisterTargets` 相当の SourceArn 制約 lambda permission) を追加する必要があり、CDK は ~30 行増える

**Alternatives considered**

| 案 | 公開ホスト名の有無 | 採否 | 却下理由 |
|---|---|---|---|
| Lambda Function URL + OAC | あり (`*.lambda-url`) | ✗ | DAST UnauthWebEndpoint を踏むリスク + ap-southeast-4 未サポート |
| API Gateway Regional + IAM auth | あり (`*.execute-api`) | ✗ | DAST UnauthWebEndpoint を踏むリスク (Function URL と同根本) |
| API Gateway Private | なし | △ | VPC 内からしか叩けないので CloudFront → 直接接続できない。VPCE 経由の構成が複雑化 |
| **ALB Lambda Target Group** | **なし** | **✓** | **採用** |

**Consequences**
- `cdk/lib/cloudfront-frontend-stack.ts` から `FunctionUrlOrigin` / `oauthLambda.addFunctionUrl` を削除する
- `cdk/lib/alb-backend-stack.ts` に OAuth Lambda + Lambda Target Group + listener rule (priority 0, path=`/oauth/*` + X-Origin-Verify match) を追加する
- CloudFront Distribution の `additionalBehaviors['/oauth/*']` は **削除**。default behavior (VPC Origin → ALB) にすべて委ねる。`/oauth/*` は CloudFront Function (viewer-request HMAC verify) を **付けない**ことだけ注意 (auth bypass のための除外設定)
- Lambda コード (`lambda/oauth-callback/index.mjs`) は ALB event shape (`event.path` / `event.queryStringParameters` / `event.headers`) を読むよう調整。Function URL 互換性は残さない (両形式 fallback は分岐が増えるだけで利得がない)

---

## ADR-012: CloudFront Function 2.0 と ALB Lambda Target の event 形状を実装で踏むまで

**Status**: Accepted (2026-05-22)

ADR-005 + ADR-011 を sa-east-1 で実 deploy + E2E 検証した過程で、ドキュメントから読み取りづらい AWS 側の振る舞いを 4 件踏んだ。今後の保守と他リージョン展開でブロッカーになりやすいので、固有名詞付きで記録する。

### 1. CloudFront Function 2.0 は Cookie ヘッダを `request.cookies` に構造化して受ける

CloudFront Function 1.0 は `request.headers['cookie'].value` に raw Cookie ヘッダ文字列が入る前提だった。2.0 ではビューワーが送ってきた Cookie ヘッダを runtime が parse して `request.cookies['<name>'].value` の構造化マップに展開する。`request.headers['cookie']` は **空** または **undefined** になることが多い。

実装上の影響:

- `request.headers['cookie']` を直接 split して cookie を取り出すコードは prod で **常に redirect-to-login する** バグになる (test-function でも 302 が返る)
- 必ず `request.cookies['cf_session'].value` を先に見て、無ければ headers にフォールバックする二段構えにする
- `parseCookie()` ヘルパーは fallback 用として残すが第一経路ではない

### 2. CF Function 2.0 で `Buffer` は使えるが string メソッドは持たない

`Buffer.from(b64, 'base64')` で Uint8Array 風の Buffer は得られるが、`.match()` や `.indexOf()` のような String 経由のメソッドは生えていない。`exp` 抽出のような正規表現用途では `Buffer.from(...).toString('utf-8')` で一度 JS string に落とす必要がある。

`String.bytesFrom()` は **deprecated**。CF Function 2.0 ランタイムでも実行時 SyntaxError でフォールス。CDK 上のテンプレートでも使ってはならない。

### 3. ALB Lambda Target で `multi_value_headers.enabled=true` のときは query string が `multiValueQueryStringParameters` にしか来ない

`event.queryStringParameters` は **undefined** で送られてくる。`event.multiValueQueryStringParameters[name][0]` で取り出さないと OAuth callback の `code` / `state` が見えず常に 400 が返る。

実装は両方の shape に対応するヘルパー (`getQueryParam(event, name)`) を経由させて、unit test で flat shape と multi-value shape の双方を返せるようにしておく。

### 4. CloudFront 経由で OAuth Lambda に到達するルート (`/oauth/*` behavior) は `ALL_VIEWER_EXCEPT_HOST_HEADER` ではなく `ALL_VIEWER` を使う

`ALL_VIEWER_EXCEPT_HOST_HEADER` を使うと CloudFront は origin に向ける際 Host ヘッダをオリジンの DNS (内部 ALB の `internal-...elb.amazonaws.com`) で書き換える。OAuth Lambda はこの Host を `redirect_uri` の組み立てに使うので、Cognito Hosted UI に内部 ALB DNS を redirect_uri として渡してしまい、UserPoolClient の callback URL allowlist と一致せずエラーになる。

`/oauth/*` behavior に限り `ALL_VIEWER` を使い、ビューワーが送った CloudFront の `dXXX.cloudfront.net` を Lambda まで通す。

### 5. default behavior (code-server) でも `ALL_VIEWER` が必須 (code-server WebSocket origin check)

当初 default behavior は `ALL_VIEWER_EXCEPT_HOST_HEADER` で良いと思っていたが、実 deploy 後にブラウザの code-server で `An unexpected error occurred ... WebSocket close with status code 1006` を踏んだ。

原因は code-server の WebSocket upgrade 処理で **`Host` ヘッダと `Origin` ヘッダのホスト部が一致するかを検証する** こと (HTTP `Origin` の同一オリジンチェック)。`ALL_VIEWER_EXCEPT_HOST_HEADER` だと CloudFront が origin に向ける際に Host を ALB の internal DNS (`internal-...elb.amazonaws.com`) で書き換えるため、ブラウザが送る `Origin: https://dXXXX.cloudfront.net` と一致せず、code-server が `403 Forbidden` で upgrade を弾く。

ローカル `curl http://127.0.0.1/stable-...` で `Origin` を付けずに upgrade すると `101 Switching Protocols` が返るのに対し、CloudFront 経由かつ `Origin` ヘッダ付きでは 403 になることで切り分けが付いた。

最終構成は **default / `/oauth/*` の両 behavior で `ALL_VIEWER` を使う**。これで code-server (Host = Origin host で WebSocket OK) と OAuth Lambda (Host = CloudFront domain で redirect_uri が正しい) の双方が viewer の `Host: dXXXX.cloudfront.net` をそのまま受け取れるようになる。

ALB 側では Host による listener rule 振り分けは行わず、X-Origin-Verify ヘッダ + path で振り分けているため Host 維持の副作用はない。

### 結論

これらは AWS の挙動ドキュメントを丹念に読めば書いてあるが、CDK サンプルや AWS 公式チュートリアル中で四隅まで明示されていることが少ない。Phase 1-4 の実 deploy で踏んでから設計に反映した。今後 ADR-005/011 系の構成を別 region / 別アカウントへ展開する際は、まずこの 5 点を smoke test に組み込むこと。

E2E smoke test のうち WebSocket upgrade は **HTTP/1.1 を明示** ( `curl --http1.1 -H "Connection: Upgrade" -H "Upgrade: websocket"` ) して 101 が返ることを必ず確認する。HTTP/2 は WebSocket upgrade メカニズムが標準的に通らないので 404/200 が返り誤検知する。

---

## ADR-013: cdk deploy 一撃で Cognito operator user を bootstrap する

**Status**: Accepted (2026-05-22)

**Context**
ADR-005〜ADR-012 で構造としての deploy は成立したが、運営者が code-server まで届くには別途 `aws cognito-idp admin-create-user` + `admin-set-user-password` を手動実行する必要があった。検証フェーズで region を切り替えるたびに out-of-band の手順が増えるのは UX として NG。Bootcamp 配布シナリオでも「envelope の中だけで完結」が要求される。

**Decision**

`deploy.sh --operator-email <email> --operator-password <pwd>` で渡された認証情報を以下の経路で扱う:

```
[deploy.sh]
   |
   | 1. Secrets Manager に <stackName>-operator-password を作成 / 更新
   | 2. CDK には Secret ARN だけを context (-c operatorPasswordSecretArn=...) で渡す
   | 3. ローカル shell の OPERATOR_PASSWORD 変数を即座に空文字に上書き
   v
[CognitoOperatorStack]
   |
   | 4. operatorEmail + operatorPasswordSecretArn が両方揃ったときだけ
   |    Custom Resource (Lambda-backed Provider) を生成
   v
[Custom Resource Lambda  cdk/lambda/cognito-bootstrap-user/index.mjs]
   |
   | 5. Secrets Manager から password を読み出し (実行時のみ)
   | 6. AdminCreateUser (MessageAction=SUPPRESS, email_verified=true)
   |    - UsernameExistsException は idempotent 扱いで無視
   | 7. AdminSetUserPassword (Permanent=true)
   v
[Cognito UserPool]
   既に email_verified + permanent password で登録済み →
   FORCE_CHANGE_PASSWORD challenge を経由せず Hosted UI で直接ログイン可
```

`--full` ショートカットを追加し、`--create-efs --create-alb-backend --create-cognito --create-cloudfront-frontend` を一括有効化できるようにした。

**Why password は CFN template に入れない**

- `-c operatorPassword=<plain>` を直接 Custom Resource Property に入れると、cdk.out / CFN drift detection / `describe-stack-resources` の Properties に plaintext が残る (CFN は ResourceProperties を hash してしか比較しないので、現状の cloudformation drift にも plaintext が含まれる)
- Secrets Manager に書いた値は `GetSecretValue` 履歴に残るが、Properties や drift の plaintext は残らない
- Lambda の `grant_read` で必要最小権限 (`secretsmanager:GetSecretValue`) のみ付与
- `OPERATOR_PASSWORD` shell 変数は Secrets Manager に書き込んだ直後に空文字で上書きしてプロセス memory にも残さない

**Why Custom Resource (AwsCustomResource ではなく Lambda)**

- AwsCustomResource は Properties に渡された値を CFN template にそのまま埋め込む。`Password=` を直接渡すと plaintext が CFN に残る
- 自前 Lambda にすると「Password Secret ARN を Properties に埋め込み、Lambda が runtime に Secret を読む」分離が成立する
- AdminCreateUser と AdminSetUserPassword を 1 回の呼び出しで連続実行する際の例外処理 (UsernameExistsException の idempotent 化) も自前 Lambda 側で表現できる

**Consequences**

- `cdk deploy` 1 発で「ブラウザを開いて email + password でログインできる」状態まで到達する
- Cognito password policy (>= 12 chars, lower/upper/digit) を deploy.sh 側でも事前 validate するので、Custom Resource 失敗による rollback を回避
- `--operator-password-secret-arn <arn>` で既存 secret の流用も可 (Bootcamp で運営者が手動管理する secret を流用するケース)
- destroy 経路では Lambda の Delete event は no-op。UserPool 自身が `RemovalPolicy.DESTROY` で消えるので user は同時に消える
- Bootstrap される user は 1 名のみ (operator)。追加 user は従来通り `aws cognito-idp admin-create-user` で out-of-band

**Alternatives considered**

| 案 | 採否 | 理由 |
|---|---|---|
| `-c operatorPassword=<plain>` を Properties にそのまま | ✗ | CFN template / drift に plaintext が残る |
| AwsCustomResource (provider なし) | ✗ | Properties が CFN に埋まる、AdminCreateUser + AdminSetUserPassword の 2 step 連続実行と例外制御が表現しづらい |
| Cognito 側で TemporaryPassword を auto-generate して email 送信 | ✗ | SES 設定と検証された送信元アドレスが必要、検証 region 都度設定するのは運用負荷 |
| **deploy.sh が Secrets Manager に書く + Lambda Custom Resource で適用** | **✓** | **採用** |

---

## ADR-010: 削除するファイル

**Status**: Accepted (2026-05-22)

ADR-002, ADR-004 の決定により、以下のファイルは ADR-005 採用案では使わない:

| ファイル | 理由 |
|---|---|
| `cdk/lib/verified-access-stack.ts` | ADR-002 で VA 不採用 |
| `cdk/lib/edge-auth/index.ts` | ADR-004 で Lambda@Edge 不採用 |
| `cdk/lib/edge-auth/edge-auth-construct.ts` | 同上 |
| `cdk/lib/cloudfront-codeserver-stack.ts` | 旧 Lambda@Edge 案の遺物 |
| `bin/app.ts` の `createVerifiedAccess` 分岐 | ADR-002 で不要 |

これらは Phase D (CloudFront 案) 実装のタイミングで一括削除する。それまで参照されないまま温存しても害はない。

---

## 参考: 検討時の比較表

### 認証経路の選択

| 案 | code-server アクセス | API アクセス | ドメイン | リージョン跨ぎ | 採否 | 却下理由 |
|---|---|---|---|---|---|---|
| Verified Access (VA) | ブラウザ | ブラウザ | **必要** | なし | ✗ | ACM cert 必須 (ADR-002) |
| ALB HTTPS listener | ブラウザ | ブラウザ | **必要** | なし | ✗ | ACM cert 必須 (ADR-003) |
| Lambda@Edge OAuth | ブラウザ | ブラウザ | 不要 | **us-east-1 強制** | ✗ | リージョン跨ぎ (ADR-004) |
| CloudFront Function + RSA JWT | ブラウザ | ブラウザ | 不要 | なし | △ | 1ms 制約綱渡り (ADR-005 で改良) |
| **CloudFront Function + HMAC (ADR-005)** | **ブラウザ** | **ブラウザ** | **不要** | **なし** | **✓** | **採用** |
| SSM port forward 単独 | CLI (localhost) | 別経路 | 不要 | なし | ✗ | ブラウザ共有不可 (ADR-006) |
| SSM + CloudFront API ハイブリッド | CLI | ブラウザ | 不要 | なし | ✗ | ブラウザ共有不可 (ADR-006) |

### OAuth Lambda の expose 方法 (ADR-011)

| 案 | 公開ホスト名 | region 制約 | 採否 |
|---|---|---|---|
| Lambda Function URL + OAC | `*.lambda-url.<region>.on.aws` (公開) | ap-southeast-4 等で未サポート | ✗ |
| API Gateway Regional + IAM auth | `*.execute-api.<region>.amazonaws.com` (公開) | なし | ✗ |
| API Gateway Private | なし (VPCE 経由のみ) | なし | △ (構成複雑) |
| **ALB Lambda Target Group** | **なし** (internal ALB) | **なし** | **✓ 採用** |

---

## このドキュメントの更新方針

- ADR は **不変** が原則。決定を覆す場合は新しい ADR を立てて旧 ADR の Status を `Superseded by ADR-NNN` に更新する
- 「今こうなっている」は DESIGN.md、「なぜそうなっているか」はこの ADR
- 議論の経緯ではなく **判断の根拠** だけを残す。Architect agent との会話ログ等は残さない
