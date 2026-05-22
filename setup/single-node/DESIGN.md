# single-node Trainium 検証基盤 設計資料

**作業ブランチ**: `feature/cloudfront-cognito-codeserver-access`
**作業ディレクトリ**: `/Users/akazawt/.work/aws-neuron-samples/setup/single-node/`
**最終更新**: 2026-05-22
**目的**: 運営者ブラウザから CloudFront 経由で認証付き code-server に到達する経路を最優先で成立させる。StoreAI デモ用の app routing (LLM/VTON/Whisper/Avatar) は同じ ALB に後付け、別 phase。
**現フォーカス region**: **sa-east-1** (Trn2 検証と整合、Lambda Function URL 制約も回避)。ap-southeast-4 sandbox は AWS::Lambda::Url 未サポートで保留。

このドキュメントは「**今合意していること** と **今後決めること**」を 1 ファイルに固定し、混乱したらここに戻れば共通理解を再構築できるようにするためのものです。

> **判断の根拠については [ARCHITECTURE_DECISIONS.md](./ARCHITECTURE_DECISIONS.md) を参照**
> 「ドメインを使わないのに認証付き code-server をブラウザに見せる」「Verified Access ではなく CloudFront Function + HMAC opaque cookie を選んだ」など、非自明な設計判断の必然性は ADR ファイルに分離してあります。「なぜこうなっているのか」を疑問に思ったら先に ADR を読んでください。

---

## 0. 合意事項 (Q1〜Q6)

会話で何度か揺れたので、最終的な合意を固定します。

### Q1. Lambda@Edge は使わない

- Lambda@Edge は **us-east-1 強制** で、backend (us-east-2) と分離させると stack split が発生し複雑化
- 認証は **Lambda@Edge 以外の方法**で実現する
- 既に書いた `cdk/lib/edge-auth/` 配下のコードは **未参照のまま温存**、後で削除

### Q2. 認証メカニズム = AWS Verified Access + IP allowlist + CloudFront

- AWS Verified Access (VA) を **backend region (us-east-2) に立てる**
  - VA は WebACL や Lambda@Edge と違って us-east-1 制約がない
  - Cognito UserPool を OIDC trust provider として直接統合できる
- WAF / IP allowlist は CloudFront 層で持つ
- 防御層を 6 段に積む (詳細は §2)

### Q3. 検証 region は **sa-east-1**、ap-southeast-4 sandbox は保留

- **sa-east-1**: trn2.3xlarge の Spot/On-Demand 在庫があり、現在 KTF-Spot-Manual 等の Trn2 検証スタックも sa-east-1 で稼働中。Lambda Function URL もサポート (region は古く CFN リソース対応済み)
- **ap-southeast-4** での sandbox 構築 (`storeai-validation-ap4-*`) は EC2/EFS/ALB/Cognito まで完了したが、**`AWS::Lambda::Url` が未サポート**で frontend stack が deploy できず保留 (`describe-type` で `TypeNotFoundException` 確認済み)
- ADR-011 で OAuth Lambda は **ALB Lambda Target Group で expose** する方針に変更したため、Function URL の region 制約自体が消える。ap-southeast-4 でも将来再開できるが、現フォーカスは sa-east-1
- Trn2.48xlarge 大規模検証は別タスク (us-east-2 Capacity Block 経由) として分離。本資料の対象は **sa-east-1 sandbox での CloudFront → code-server 到達**を最優先

### Q4. ALB は internal、ドメイン持ち込みなし、Verified Access が前段

- **ALB は internal (private subnet)** とする
  - public IP / public DNS を持たない
  - SG inbound = VA VPCE の prefix list (`com.amazonaws.<region>.vpce`) 経由のみ
  - **DAST UnauthWebEndpoint 検出の根本原因 (public web endpoint) を完全に消す**
- カスタムドメインは持ち込まない
  - CloudFront default `*.cloudfront.net` を使う
  - VA endpoint の AWS マネージド hostname `vae-xxx.elb.<region>.vpce.amazonaws.com` を使う
- Verified Access endpoint が CloudFront origin / 認証ゲート

### Q5. EFS 永続化を CDK で作る

- EFS file system + 3 AZ mount target を CDK で作成
- EFS stack は EC2 stack と独立 (lifecycle 分離)
  - Spot 中断後の再 deploy で NEFF キャッシュ + HF モデル重みを保持
- EC2 SG → EFS MT SG の NFS (TCP 2049) ingress は deploy.sh が自動付与
- 実装済み (commit 前): `cdk/lib/efs-persistence-stack.ts` / `bin/app.ts` の `createEfs` flag / `deploy.sh --create-efs`

### Q6. アプリ API トラフィック経路 (StoreAI フロントエンドからの呼び出し)

StoreAI の構成:
```
Operator/User Browser
  ↓
Next.js (CloudFront + S3 で配信される静的 SPA)
  ↓
Lambda
  ↓ (HTTPS, X-Origin-Verify ヘッダ付き)
ALB (internal)
  ↓
EC2 trn2.48xlarge
  ├─ docker container A: Qwen3-8B   listen :8080
  ├─ docker container B: Qwen-Image-Edit listen :8081
  ├─ docker container C: Whisper-Neuron  listen :8765
  └─ (4 つ目があれば追加で listen)
```

要件:
- **同じ ALB が code-server (port 80) と複数アプリ port (8080/8081/8765/...) を受け止める**
- **Lambda が各アプリ port を叩けるよう listener rule を設定**
- アプリ API リクエストは **Verified Access をバイパス** する経路を持つ (人間ユーザーではなく Lambda が機械的に叩くため、Cognito Hosted UI のリダイレクトを通さない)

---

## 1. 全体アーキテクチャ

ADR-005 + ADR-011 に基づく構成。CloudFront origin は **VPC Origin → 内部 ALB の 1 本に集約**。OAuth Lambda は ALB Lambda Target Group で expose し、Function URL / API Gateway は使わない。

```
┌──────────────────────────────────────────────────────────────────┐
│  運営者ブラウザ                                                   │
└────────────┬─────────────────────────────────────────────────────┘
             │ HTTPS https://dXXXX.cloudfront.net (default cert)
             ▼
┌──────────────────────────────────────────────────────────────────┐
│  CloudFront Distribution                                         │
│   Viewer-Request: CloudFront Function (HMAC verify cf_session)   │
│      無効/欠如 → 302 /oauth/login                                 │
│   ※ /oauth/* behavior には CF Function を付けない (auth bypass)   │
│   Origin = VPC Origin (内部 ALB :80)                              │
│   Custom Origin Header: X-Origin-Verify: <secret>                │
└────────────┬─────────────────────────────────────────────────────┘
             │ VPC Origin → internal ALB
             ▼
┌──────────────────────────────────────────────────────────────────┐
│  ALB (internal, sa-east-1, private subnet)                       │
│  SG inbound: CloudFront origin-facing prefix list のみ            │
│  Listener (HTTP :80) rules (priority 順):                         │
│    1. /oauth/*     [X-Origin-Verify] → TG (Lambda)  ← ADR-011    │
│    2. /api/llm/*   [X-Origin-Verify] → TG :8090 (Qwen3 LLM)      │
│    3. /api/vton/*  [X-Origin-Verify] → TG :8081 (Qwen-Img-Edit)  │
│    4. /api/whisper/* [X-Origin-Verify] → TG :8765 (Whisper)      │
│    5. /api/avatar/*  [X-Origin-Verify] → TG :8770 (MuseTalk 将来)│
│    1000. /*        [X-Origin-Verify] → TG :80 (code-server)      │
│  default action: 403 fail-closed                                 │
└──────┬─────────────────────────────────────┬─────────────────────┘
       │ /oauth/* (Lambda invoke)            │ ALB SG → EC2 SG
       ▼                                      ▼
┌──────────────────────┐      ┌──────────────────────────────────┐
│  OAuth Lambda        │      │  EC2 (trn2.3xlarge in sa-east-1) │
│  (sa-east-1)         │      │  DLAMI Neuron Ubuntu 24.04        │
│  - /oauth/login      │      │  SG inbound: ALB SG のみ          │
│  - /oauth/callback   │      │                                   │
│  Cognito Hosted UI と│      │  code-server :80 (常駐)           │
│  OAuth code 交換 →    │      │  (StoreAI app container は別 phase)│
│  HMAC opaque cookie  │      │                                   │
│  を Set-Cookie       │      │  /home/coder, /work, /opt/ml/cache│
│                      │      │     → EFS マウント                 │
│  権限: cognito-idp:  │      └────────────┬──────────────────────┘
│   ListUserPoolClients│                   │ NFS 2049
│   DescribeUserPool   │                   ▼
│   Client             │      ┌──────────────────────────────────┐
└──────────┬───────────┘      │  EFS (sa-east-1, 3 AZ MT)        │
           │ HTTPS             │  - NEFF キャッシュ                │
           ▼                   │  - HuggingFace モデル重み         │
┌──────────────────────┐      │  - code-server config             │
│ Cognito UserPool     │      └──────────────────────────────────┘
│ Hosted UI            │
│ (*.amazoncognito.com)│
└──────────────────────┘
```

**重要ポイント**:
- ALB が internal scheme + zero ingress (CloudFront prefix list のみ) のため、**OAuth Lambda は外部から DNS resolve できない**。これが ADR-011 で Function URL / API Gateway を採用しない理由
- CloudFront → ALB 区間は VPC Origin (2024-11 GA) で HTTP。CloudFront 側で TLS 終端されているのでブラウザ視点では HTTPS
- code-server は EC2 上で port :80 (nginx → :8080) で listen。StoreAI app container は別 phase で `/api/*` ルートに後付け

---

## 2. セキュリティ防御層 (6 段)

| # | 層 | 機構 | 防ぐもの |
|---|---|---|---|
| 1 | CloudFront WAF | IP allowlist (priority 0) + managed rules + rate limit | DAST スキャナ / bot / DDoS |
| 2 | CloudFront → ALB / VA | X-Origin-Verify ヘッダ (Secrets Manager 生成) | 直叩きアクセス (CloudFront 経由でない) |
| 3 | Verified Access (default behavior) | Cognito Hosted UI 認証 + Cedar policy (IP + email) | 未認証ユーザー / 許可外ユーザー |
| 4 | ALB SG | inbound = VA VPCE prefix list のみ + (api 用) CloudFront prefix list | ALB DNS 漏洩でも直叩き不可 |
| 5 | ALB listener default | 403 fail-closed + listener rule で X-Origin-Verify match 必須 | rule にマッチしない全リクエスト |
| 6 | code-server password (DLAMI 既定) | password 認証 | 全層突破されても人間突破は困難 |

特に DAST UnauthWebEndpoint 検出の観点:
- ALB が **internal** で public IP / public DNS なし → 外部スキャナがそもそも到達できない
- WAF IP allowlist (#1) で許可 IP 以外を CloudFront 段で 403 → DAST が `/login` を読めない
- Verified Access (#3) が認証必須 → 「unauth web endpoint」自体が存在しない

---

## 3. CDK Stack 構成

ADR-011 採用後の構成。全 stack を sa-east-1 (検証 region) に集約。CloudFront Distribution はリージョンレスなので同 stack 内に置く。

```
bin/app.ts (sa-east-1 単一 region)
  │
  ├─ EfsPersistenceStack          (sa-east-1)
  │    EFS file system + 3 AZ MT + EFS MT SG (zero ingress 初期)
  │    Output: EfsId / EfsMtSgId
  │
  ├─ NeuronCodeServerStack         (sa-east-1)  ※既存、変更なし
  │    EC2 (trn2.3xlarge Spot) + EC2 SG (zero ingress 初期)
  │    user-data: code-server :80 (nginx -> :8080) 起動
  │    Output: InstanceId / SecurityGroupId / SecretArn (code-server pw)
  │
  ├─ AlbBackendStack              (sa-east-1)
  │    内部 ALB + ALB SG (zero ingress 初期、CloudFront stack で prefix list 追加)
  │    Listener (HTTP :80, default 403 fail-closed)
  │    Listener rules (priority 順):
  │      - /oauth/*       + X-Origin-Verify → TG (Lambda)        ← ADR-011 で追加
  │      - /api/llm/*     + X-Origin-Verify → TG :8090  (Qwen3 LLM)
  │      - /api/vton/*    + X-Origin-Verify → TG :8081  (Qwen-Image-Edit)
  │      - /api/whisper/* + X-Origin-Verify → TG :8765  (Whisper)
  │      - /api/avatar/*  + X-Origin-Verify → TG :8770  (MuseTalk 将来)
  │      - /*  (priority 1000) + X-Origin-Verify → TG :80 (code-server)
  │    OAuth Lambda (Node.js 20):
  │      env: COGNITO_USER_POOL_ID, COGNITO_DOMAIN, HMAC_SECRET, SESSION_TTL_SECONDS
  │      IAM: cognito-idp:ListUserPoolClients, DescribeUserPoolClient
  │    Lambda Permission: ALB Target Group のみが invoke 可能 (SourceArn 制約)
  │    EC2 SG への ALB SG ingress 追加 (port 80 ほか)
  │    EFS MT SG への EC2 SG ingress 追加 (port 2049)
  │    Backend Construct: Ec2InstanceBackend (既存実装を流用)
  │    Output: AlbArn / AlbSgId / OriginVerifySecretArn / OAuthLambdaArn
  │
  ├─ CognitoOperatorStack          (sa-east-1)
  │    Cognito UserPool (admin-create-user only, MFA optional)
  │    Hosted UI domain (prefix is sanitized to remove cognito/amazon/aws)
  │    UserPoolClient はここでは作らない (callback URL が CloudFront 確定後にしか決まらないため)
  │    Output: UserPoolId / UserPoolArn / UserPoolDomain
  │
  └─ CloudFrontFrontendStack       (sa-east-1, ただし CloudFront 自体は global)
       HMAC session secret (Secrets Manager)
       CloudFront Function (viewer-request HMAC verify)
       CloudFront Distribution:
         Origin: VPC Origin → AlbBackendStack の ALB (HTTP :80)
                 Custom Origin Header: X-Origin-Verify: <AlbBackend の secret>
         Default behavior:
           CF Function (viewer-request) で cf_session 検証
           CACHING_DISABLED, ALL_VIEWER_EXCEPT_HOST_HEADER
         /oauth/* behavior:
           CF Function を付けない (auth 中なので bypass)
           default behavior と同じ origin (= ALB)、cache disabled
       UserPoolClient (callback URL = この distribution の domain)
       ALB SG への CloudFront origin-facing prefix list ingress 追加
       Output: CloudFrontDomain / UserPoolClientId / CognitoCallbackUrl
```

**依存方向**: `Efs → EC2 → AlbBackend → CloudFrontFrontend` および `Cognito → CloudFrontFrontend` (sa-east-1 内、線形、循環なし)。`destroy` は逆順。

**ADR-011 採用前との差分**:
- `CloudFrontFrontendStack` から `FunctionUrlOrigin` / OAuth Lambda 関連を **削除**。OAuth Lambda は `AlbBackendStack` 側に移動
- CloudFront Distribution の `additionalBehaviors['/oauth/*']` の `origin` は default behavior と **同じ ALB**。CF Function だけ付けない違い
- ALB listener rule に priority 0 で `/oauth/*` の Lambda forward が追加される

---

## 4. 実装フェーズ分割

ADR-011 採用後の構成を sa-east-1 で順に立てる。Phase 1〜4 が「CloudFront → code-server」最優先、Phase 5 以降は StoreAI app routing 用 (別タスク)。

### Phase 1: EC2 + EFS deploy

**目的**: sa-east-1 で trn2.3xlarge Spot + EFS の起動確認

**作業**:
1. cdk synth でエラーなさを再確認
2. `bash scripts/deploy.sh --region sa-east-1 --instance-type trn2.3xlarge --use-spot --spot-interruption-behavior stop --create-efs --stack-name storeai-validation-sae1`
3. SSM port forwarding で code-server に到達確認 (CloudFront 経路完成までの仮口)
4. EFS mount 確認

**完了基準**:
- EC2 / EFS Stack が CREATE_COMPLETE
- code-server が SSM 経由で開く

### Phase 2: AlbBackendStack (OAuth Lambda 込み)

**目的**: ALB を立てて、code-server TG と OAuth Lambda Target Group を同 stack で構築 (ADR-011)

**作業**:
1. `cdk/lib/alb-backend-stack.ts` を以下の項目で更新:
   - 既存の code-server TG / app TG はそのまま
   - **OAuth Lambda (Node.js 20) をこの stack 内で作成**
   - Lambda Target Group + listener rule (priority 0, path=`/oauth/*` + X-Origin-Verify)
   - Lambda Permission (`elasticloadbalancing.amazonaws.com` から TG ARN のみ invoke 可)
   - Lambda env: `COGNITO_USER_POOL_ID` / `COGNITO_DOMAIN` / `HMAC_SECRET` / `SESSION_TTL_SECONDS`
   - IAM: `cognito-idp:ListUserPoolClients` / `DescribeUserPoolClient`
2. `lambda/oauth-callback/index.mjs` を ALB event shape (`event.path`, `event.queryStringParameters`, `event.headers`) に揃える
3. ALB SG inbound はこの段階では **空のまま** (CloudFront stack で prefix list を後から追加)

**完了基準**:
- VPC 内から `curl -H "X-Origin-Verify: <secret>" http://<alb-internal-dns>/oauth/login` が 302 を返す
- 同 `/` (X-Origin-Verify あり) が code-server を返す
- ALB SG ingress が空 / EC2 SG が ALB SG のみ ingress

### Phase 3: CognitoOperatorStack

**目的**: Cognito UserPool + Hosted UI を準備 (UserPoolClient は Phase 4 で作成)

**作業**: 既に実装済み (`cdk/lib/cognito-operator-stack.ts`)。sa-east-1 で再 deploy するだけ
- UserPool (admin-create-user only, MFA optional)
- Hosted UI domain (prefix から `cognito|amazon|aws` を strip)

**完了基準**: HostedUI base URL `https://<prefix>.auth.sa-east-1.amazoncognito.com/` がブラウザで開く

### Phase 4: CloudFrontFrontendStack (ADR-011 後の構成)

**目的**: CloudFront → ALB の VPC Origin を確立し、運営者ブラウザから code-server に到達

**作業**:
1. `cdk/lib/cloudfront-frontend-stack.ts` を以下の通り改修:
   - **`FunctionUrlOrigin` / `oauthLambda.addFunctionUrl` を削除**
   - OAuth Lambda 自体もこの stack から **削除** (AlbBackendStack 側に移行)
   - Distribution の `additionalBehaviors['/oauth/*']` の origin を VPC Origin (= default behavior と同じ ALB) に変更
   - `/oauth/*` behavior には CF Function を **付けない** (auth bypass 必須)
   - HMAC secret + CloudFront Function 本体は残す
   - UserPoolClient (callbackUrl = この distribution の domain) もこの stack で作成
   - ALB SG への CloudFront origin-facing prefix list ingress 追加もここで実施
2. CDK synth → deploy

**完了基準**:
- ブラウザで `https://<distribution>.cloudfront.net/` → CF Function が cf_session 不在を検出 → 302 `/oauth/login`
- `/oauth/login` で Cognito Hosted UI にリダイレクト
- ログイン → `/oauth/callback` で `cf_session` を Set-Cookie
- 再アクセスで code-server が表示される

**E2E 検証完了 (2026-05-22, sa-east-1)**:
- distribution: `d3rehj1mrwesra.cloudfront.net` (stack: `storeai-validation-sae1-frontend`)
- 7 step E2E (`/tmp/oauth_e2e.py`, curl ベース) 全 step 成功
  - step 1: `/` → 302 `/oauth/login` (CF Function HMAC fail)
  - step 2-5: Cognito Hosted UI sign-in (`_csrf` トークン込み POST) → 302 `/oauth/callback?code=&state=`
  - step 6: callback Lambda が `cf_session` を Set-Cookie + `cf_oauth_state` を clear
  - step 7: `/` (with cf_session) → 200 で nginx/code-server に到達 (CF Function 通過)
- 実装段階で踏んだ Gotcha は ADR-012 を参照:
  1. CF Function 2.0 は cookie を `request.cookies.<name>.value` に置く
  2. `Buffer.from(b64).toString('utf-8')` してから `.match()` する
  3. ALB Lambda Target は query を `multiValueQueryStringParameters` でしか配らない
  4. `/oauth/*` behavior は `ALL_VIEWER` (Host を維持) を使う

### Phase 5: app routing (別タスク)

StoreAI 用の `/api/llm/*` `/api/vton/*` `/api/whisper/*` `/api/avatar/*` の listener rule + container 起動。Phase 4 完了後に着手。本資料では code-server 到達までを最優先とし、app routing は別 phase として切り出し。

---

## 5. ファイル一覧

### 主要ファイル

| パス | 役割 / 状態 |
|------|-------------|
| `cdk/lib/torch-neuron-stack.ts` | NeuronCodeServerStack (Phase 1)。変更なし |
| `cdk/lib/efs-persistence-stack.ts` | EFS (Phase 1)。変更なし |
| `cdk/lib/alb-backend-stack.ts` | ALB + 各種 TG (Phase 2)。**Phase 2 改修対象**: OAuth Lambda + Lambda TG + listener rule(`/oauth/*`) を追加 |
| `cdk/lib/cognito-operator-stack.ts` | Cognito UserPool + Hosted UI (Phase 3)。実装済 |
| `cdk/lib/cloudfront-frontend-stack.ts` | CloudFront + CF Function + UserPoolClient (Phase 4)。**Phase 4 改修対象**: FunctionUrlOrigin / Lambda 削除、`/oauth/*` の origin を ALB に変更 |
| `cdk/lib/backends/*` | BackendTarget interface + Ec2InstanceBackend。流用 |
| `cdk/lib/cf-functions/viewer-request.template.js` | CF Function ソース (HMAC verify)。変更なし |
| `lambda/oauth-callback/index.mjs` | OAuth Lambda 本体。**Phase 2 改修対象**: ALB event shape へ調整 |
| `cdk/bin/app.ts` | Stack 結線。region を sa-east-1 に揃える |
| `scripts/deploy.sh` | deploy ヘルパ。region 引数で sa-east-1 を指定 |

### 削除予定 / 削除済

| パス | 理由 |
|------|------|
| `cdk/lib/verified-access-stack.ts` | ADR-002 で VA 不採用 (削除済 / Phase 4 までに掃除) |
| `cdk/lib/edge-auth/*` | ADR-004 で Lambda@Edge 不採用 |
| `cdk/lib/cloudfront-codeserver-stack.ts` | 旧 Lambda@Edge 案の遺物 |

---

## 6. 未確定事項

### U1. WAF IP allowlist の運用 (ADR-009 と連動)

ADR-009 で「検証フェーズでは IP allowlist は入れない」決定済み。本番デモ前に DAST 相当のスキャンを自分で回し、検出されないことを確認した上で、必要なら本番では IP allowlist を追加する。

→ DAST スキャン手順 + IP 追加運用は `docs/operator-ip-management.md` に切り出し予定 (Phase 4 完了後)。

### U2. デプロイ前の最終チェック

Phase 4 deploy 前に必ず確認:
- [ ] ALB が internet-facing で立っていないこと (`Scheme: internal`)
- [ ] ALB SG ingress に 0.0.0.0/0 が一切ないこと
- [ ] ALB SG inbound = CloudFront origin-facing prefix list **のみ**
- [ ] EC2 SG ingress に 0.0.0.0/0 が一切ないこと
- [ ] EC2 SG inbound = ALB SG **のみ**
- [ ] OAuth Lambda に Function URL / API Gateway がついていないこと (ADR-011)
- [ ] CloudFront `/oauth/*` behavior に CF Function が associate されていないこと
- [ ] CloudFront `/oauth/*` behavior の origin が default behavior と同じ ALB であること

### U3. StoreAI app routing との接続 (Phase 5)

StoreAI 既存リポジトリ (`/Users/akazawt/.work/storeai-trainium/`) の Lambda を、この ALB の `/api/*` endpoint に向ける。Phase 4 (CloudFront → code-server) 完了後に着手。
- Lambda 環境変数 `SELF_HOSTED_LLM_ENDPOINT` 等を CloudFront URL `/api/llm/...` に設定
- X-Origin-Verify ヘッダ付与の仕組み (Secrets Manager 経由)

---

## 7. 作業の進め方

このドキュメントを **1 ファイル真実** とし、以下の流れで進める:

1. ユーザー (あなた) が「Phase X 進めて」「U-Y は (案) でいいよ」と指示
2. Claude (私) が DESIGN.md を **そのフェーズの開始前に** 都度更新 (合意済みになった項目を §0 に移動、未確定が増えたら §6 に追加)
3. Claude が実装する
4. cdk synth + 実 deploy で検証
5. 完了したら DESIGN.md 上の Phase ステータスを更新

混乱したら **DESIGN.md を見直す** ことで「いま我々が何を作ろうとしているか」「何が合意済みで何が未決か」が常に明示される。

---

## 8. 現在のステータス

### 現フォーカス: sa-east-1 で CloudFront → code-server を成立させる

| Phase | 状態 | 備考 |
|---|---|---|
| Phase 1 (EC2+EFS deploy) | sa-east-1 で未着手 | ap-southeast-4 では deploy 完了済み (保留中) |
| Phase 2 (AlbBackend + OAuth Lambda) | **次のアクション**: ADR-011 反映 | OAuth Lambda + Lambda TG + listener rule(`/oauth/*`) を ALB stack に移動 |
| Phase 3 (Cognito) | 実装済 (ap-southeast-4 deploy 完了) | sa-east-1 で再 deploy 必要 |
| Phase 4 (CloudFront) | **次のアクション**: ADR-011 反映 | FunctionUrlOrigin / Lambda を frontend stack から削除 |
| Phase 5 (app routing) | 未着手 | code-server 到達確認後に着手 |

### 保留: ap-southeast-4 sandbox

| Stack | 状態 |
|---|---|
| `storeai-validation-ap4` (EC2) | CREATE_COMPLETE |
| `storeai-validation-ap4-efs` | CREATE_COMPLETE |
| `storeai-validation-ap4-alb` | UPDATE_COMPLETE (X-Origin-Verify catch-all 追加済) |
| `storeai-validation-ap4-cognito` | CREATE_COMPLETE (UserPool `ap-southeast-4_HZhAuDnZ9`) |
| `storeai-validation-ap4-frontend` | NOT CREATED (`AWS::Lambda::Url` 未サポートで断念) |

ADR-011 採用後は Function URL を使わなくなるため、ap-southeast-4 でも frontend stack を deploy できるようになる。ただし現フォーカスは sa-east-1 で、ap-southeast-4 sandbox の再開は当面後回し。

### sa-east-1 deploy コマンド (Phase 1)

```bash
cd /Users/akazawt/.work/aws-neuron-samples/setup/single-node/cdk

AWS_PROFILE=claude-code AWS_REGION=sa-east-1 AWS_DEFAULT_REGION=sa-east-1 \
  bash scripts/deploy.sh \
    --region sa-east-1 \
    --instance-type trn2.3xlarge \
    --use-spot --spot-interruption-behavior stop \
    --create-efs \
    --stack-name storeai-validation-sae1 \
    --project storeai \
    --purpose phase0-validation
```

### us-east-2 Capacity Block (別タスク)

us-east-2 の trn2.48xlarge Capacity Block 予約は大規模検証用 (具体的な reservation id / 予約時刻は SSM Parameter Store `/capacity-block/us-east-2/reservation-id` 等から CDK が解決)。本資料の対象 (sa-east-1 sandbox) とは独立に進む。
