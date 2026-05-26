# voice-image-edit デプロイガイド

このドキュメントは、`setup/single-node` の基盤スタック (`neuron-ws` 系) の上に
`samples/voice-image-edit/app` のアプリケーション層をどう載せたか、そして
ゼロから / 更新時にどう動かすかを 1 ファイルにまとめたものです。

- 場所: `<repo>/samples/voice-image-edit/DEPLOYMENT_GUIDE.md`
- 対象: voice-image-edit を新規構築する人 / 再デプロイする人 / トラブルシュートする人

---

## 1. 全体アーキテクチャ

### 1.1 二段構成 (基盤レイヤー + アプリレイヤー)

このサンプルは「再利用可能な基盤」と「アプリ固有のルーティング」を完全に分離しています。

```
[ ブラウザ ]
     |
     v  HTTPS
+-----------------------------------------------------------+
|                 CloudFront (`neuron-ws-frontend`)         |
|  - viewer-request Function (HMAC verify, ~0.05ms)         |
|  - 単一 origin = Internal ALB (VPC Origin)                |
|  - Cognito UserPoolClient (callback = dXXXX.cloudfront.net|
|                            /oauth/callback)               |
+--------------------|--------------------------------------+
                     | X-Origin-Verify ヘッダ注入
                     v (内部 ALB)
+-----------------------------------------------------------+
|         Internal ALB :80 (`neuron-ws-alb`)                |
|  Listener default: 403 (fail-closed)                      |
|  Listener rules (path + X-Origin-Verify 完全一致):        |
|   pri 1   /oauth/*       -> OAuth Lambda (Lambda Target)  |
|   pri 100 /api/edit/*    -> EC2:8801 (FastAPI/uvicorn)    |  <- voice-image-edit
|   pri 150 /stream/*      -> EC2:8800 (FastAPI/uvicorn)    |  <- voice-image-edit
|   pri 200 /, /edit*,     -> EC2:3000 (Next.js standalone) |  <- voice-image-edit
|          /manage*, /_next/*                               |
|   pri 1000 /*            -> EC2:80   (code-server)        |
+-----------------------|-----------------------------------+
                        | (default VPC, EC2 SG ingress は
                        |  ALB SG からの port 別)
                        v
+-----------------------------------------------------------+
|                EC2 (`neuron-ws` Stage 1)                  |
|  Trn2 / DLAMI Ubuntu 24.04, SSM-only, EFS マウント        |
|  systemd units:                                           |
|   - voice-image-edit-frontend.service (Node 18+, :3000)   |
|   - voice-image-edit-api.service      (uvicorn,    :8801) |
|   - voice-image-edit-stream.service   (uvicorn,    :8800) |
|   - code-server                       (              :80) |
|  IAM Role (`neuron-ws` 由来) に追加で attach:             |
|   - bedrock:InvokeModel / Converse* (us-east-1)           |
|   - transcribe:StartStreamTranscription                   |
|   - s3:Put/Get on EditResultBucket                        |
+-----------------------------------------------------------+
                                 |
                                 v
                  +----------------------------+
                  |  Cognito UserPool +        |
                  |  Hosted UI                 |
                  |  (`neuron-ws-cognito`)     |
                  +----------------------------+

外部:
  - Bedrock (us-east-1 既定):
      ASR     = bedrock_transcribe (Amazon Transcribe Streaming)
      VLM     = amazon.nova-lite-v1:0
      EDIT    = amazon.nova-canvas-v1:0
      Review  = amazon.nova-lite-v1:0
  - S3 EditResultBucket (1 日 expire) ... presigned URL でフロントへ返却
  - EFS (`neuron-ws-efs`) ... /home/coder, /work をホスト跨ぎで永続化
```

### 1.2 セキュリティモデル

- **ALB は internal**。CloudFront VPC Origin 以外から直接到達できない
- **ALB SG の inbound** は CloudFront origin-facing managed prefix list のみ
- 全 listener rule で **`X-Origin-Verify` ヘッダ完全一致** を要求 (CloudFront からの注入のみ通す)
- **EC2 SG の inbound** は ALB SG からの port 別のみ。0.0.0.0/0 は一切無し
- HMAC-SHA256 で `cf_session` 不可逆 cookie を発行、CloudFront Function が viewer-request で検証
- Cognito UserPool は self-signup off (admin-create-user 経由のみ)

---

## 2. レイヤー別の構成

### 2.1 基盤レイヤー: `setup/single-node`

CDK アプリ: `setup/single-node/cdk/bin/app.ts`
デプロイスクリプト: `setup/single-node/scripts/deploy.sh`

`-c` フラグで段階的に有効化される 5 スタック:

| スタック | クラス (lib/) | 役割 |
|---|---|---|
| `neuron-ws` | `torch-neuron-stack.ts` | 単一 EC2 (Trn2 等) + IAM Role + SG (zero ingress) |
| `neuron-ws-efs` | `efs-persistence-stack.ts` | EFS + per-AZ mount target (NFS は deploy.sh が後付け) |
| `neuron-ws-cognito` | `cognito-operator-stack.ts` | Cognito UserPool + Hosted UI domain |
| `neuron-ws-alb` | `alb-backend-stack.ts` | Internal ALB + 5 TG + OAuth Lambda + HMAC/OriginVerify Secrets |
| `neuron-ws-frontend` | `cloudfront-frontend-stack.ts` | CloudFront + viewer-request Function + UserPoolClient |

依存関係:

```
neuron-ws-frontend
    ├── neuron-ws-alb         (UserPoolClient callback URL を decide できないため)
    │      └── neuron-ws-cognito  (OAuth Lambda が UserPool 参照、ADR-011)
    └── neuron-ws-cognito
neuron-ws-efs (独立)
neuron-ws (独立、ただし ALB Stack が InstanceId / SgId を context で受け取る)
```

`deploy.sh --full` 1 発で 5 スタック全部立てられます (本ガイド §3.1)。

### 2.2 アプリレイヤー: `samples/voice-image-edit/app/infra`

CDK アプリ: `samples/voice-image-edit/app/infra/bin/app.ts`
デプロイスクリプト: `samples/voice-image-edit/app/infra/deploy.sh`

3 スタック構成 (基盤の `neuron-ws-alb` の Listener にルールを追加するだけ):

| スタック | クラス (lib/) | 何を作るか | ALB rule priority |
|---|---|---|---|
| `VoiceImageEditApiStack` | `api-stack.ts` | EC2:8801 を IP target にする TG + path `/api/edit/*` のルール + EditResultBucket (S3) + EC2 IAM への追加権限 (bedrock / transcribe / s3) | 100 |
| `VoiceImageEditStreamStack` | `stream-stack.ts` | EC2:8800 を IP target にする TG + path `/stream/*` のルール | 150 |
| `VoiceImageEditFrontendStack` | `frontend-stack.ts` | EC2:3000 を Instance target にする TG + path `/, /edit*, /manage*, /_next/*` のルール | 200 |

すべて **既存リソース参照のみ**:
- ALB ARN / Listener ARN / ALB SG ID は CFN Outputs から自動解決
- `OriginVerifySecret` を `Secret.fromSecretCompleteArn` で読み、synth-time に値を inline
  → ListenerRule の header 完全一致条件に値が埋め込まれる
- EC2 SG に `albSg -> ec2Sg port N` の ingress を CDK が冪等に追加
- 既存 EC2 IAM Role に `addToPrincipalPolicy()` で Bedrock / Transcribe / S3 を後付け
  (基盤スタックの差分は出ない)

### 2.3 アプリ本体 (EC2 上で動くもの)

| サービス | コード | systemd unit | port | デプロイ手段 |
|---|---|---|---|---|
| Frontend | `app/frontend/` (Next.js 14 standalone) | `voice-image-edit-frontend.service` | 3000 | `infra/tasks/voice-image-edit-frontend.json` |
| API | `app/backend/api/` (FastAPI/uvicorn) | `voice-image-edit-api.service` | 8801 | `infra/tasks/voice-image-edit-api.json` |
| Stream | `app/backend/stream/` (FastAPI/uvicorn, SSE) | `voice-image-edit-stream.service` | 8800 | `infra/tasks/voice-image-edit-stream.json` |

タスク定義は **JSON Task Runner 経由で SSM Run Command** に流します
(`setup/single-node/scripts/run-tasks.sh`)。
直接 SSH は禁止 (基盤の運用ルール)。

---

## 3. 手順書

### 3.1 ゼロから新規構築 (基盤 + アプリ)

前提:
- `AWS_PROFILE=claude-code` (これ以外禁止)
- 利用リージョン (例: `sa-east-1` Trn2 用 / `us-west-2` 等)
- Bedrock 利用リージョン (例: `us-east-1`)
- node 18+, npm, jq, aws CLI, session-manager-plugin

```bash
export AWS_PROFILE=claude-code
export AWS_REGION=sa-east-1
export AWS_DEFAULT_REGION=sa-east-1
```

#### ステップ A. 基盤を 1 発で立てる

```bash
cd <repo>/setup/single-node/scripts

bash deploy.sh \
  -r sa-east-1 \
  --use-spot --spot-interruption-behavior stop \
  --stack-name neuron-ws \
  --full \
  --operator-email admin@example.com \
  --operator-password 'ChangeMe-Strong123'
```

`--full` で `--create-efs --create-alb-backend --create-cognito --create-cloudfront-frontend` が
全部 ON になります。完了すると以下が立ちます:

- `neuron-ws-efs`     (EFS + MT SG, 自動で NFS ingress 開放)
- `neuron-ws-cognito` (UserPool + Hosted UI、operator user 1 名 bootstrap)
- `neuron-ws`         (Trn2 Spot EC2、SSM 経由のみ)
- `neuron-ws-alb`     (Internal ALB + OAuth Lambda + 5 TG)
- `neuron-ws-frontend` (CloudFront + UserPoolClient + ALB SG inbound)

最後に `CloudFront URL` (例: `https://dXXXXXXXX.cloudfront.net/`) が出ます。
このドメインで Cognito Hosted UI にログインできれば基盤は OK。

> 注意: `neuron-ws-frontend` は CloudFront のため propagate に 5–15 分かかります。
> `Status=Deployed` になるまで HTTP 504 や 403 が一時的に出ますが正常です。

#### ステップ B. アプリ層を後付け

```bash
cd <repo>/samples/voice-image-edit/app/infra

bash deploy.sh \
  --base-stack-name neuron-ws \
  -r sa-east-1 \
  --bedrock-region us-east-1
```

`deploy.sh` が以下を **1 発で全部** 実行します (P15 で Frontend / Stream も自動化済み):

1. 基盤 stack (`neuron-ws-alb`) の outputs から ALB ARN / Listener ARN / ALB SG / OriginVerifySecretArn / AlbDnsName を解決
2. 基盤 stack (`neuron-ws`) の outputs から EC2 InstanceId / SgId を取り、describe-instances で
   PrivateIp / VpcId / IAM Role 名を補完
3. `npm install` (idempotent) → `cdk deploy VoiceImageEditApiStack VoiceImageEditFrontendStack VoiceImageEditStreamStack`
4. **API**: `app/backend/api/` を `tar -czf` → CDK bootstrap bucket
   (`cdk-hnb659fds-assets-<account>-<region>`) に upload → presigned URL を生成
   → `setup/single-node/scripts/run-tasks.sh` で `tasks/voice-image-edit-api.json` を SSM Run Command に流す
   (00-precheck → 10-stop → 20-deploy-tarball → 30-create-venv → 40-install-systemd-unit → 50-enable-start → 60-health-check)
5. **Frontend**: `app/frontend/` で `npm ci` + `npm run build` (next standalone) →
   `.next/standalone` + `.next/static` + `public` を結合した tarball を upload → presigned →
   SSM で `tasks/voice-image-edit-frontend.json` を実行 (00-precheck → 50-health-check)
6. **Stream**: `app/backend/stream/` を `tar -czf` → upload → presigned →
   ALB DNS と OriginVerifySecret 値を解決して SSM で `tasks/voice-image-edit-stream.json` を実行

完了すると EC2 上で 3 つの systemd unit (`voice-image-edit-api/frontend/stream`) が常駐し、
ALB 経由で `https://<cloudfront>/api/edit/health` / `/edit` / `/stream/health` がすべて 200 を返します。

> `ORIGIN_VERIFY_HEADER_VALUE` は Secrets Manager から取り出した直後に jq の `--arg` で systemd Environment に
> 限定して引き渡しています。`set -x` や stdout / log には出ない構成です (HMAC secret と同等の機密扱い)。

主なオプション (個別に skip したい場合):

| フラグ | 効果 |
|---|---|
| `--skip-api` / `--skip-frontend` / `--skip-stream` | 該当 stack を CDK ごとスキップ |
| `--skip-api-deploy` / `--skip-frontend-deploy` / `--skip-stream-deploy` | CDK は流すが SSM 配備をスキップ (権限のみ更新したい等) |
| `--frontend-no-build` | `npm ci` + `npm run build` をスキップして既存 `.next/standalone` を再利用 |

#### ステップ C. 動作確認

ブラウザで `https://<CloudFront ドメイン>/edit` を開き、Cognito Hosted UI にログインすると
`/edit` 画面が表示されます。
- 画像をドロップ → 録音 → 編集ボタン → SSE で 4 段パイプラインが進行
- Stage: ASR (skipped) → vlm_instruction → edit → vlm_review

---

### 3.2 アプリのみ更新 (基盤は触らない)

すべて同じ `deploy.sh` のフラグ組み合わせで対応できます。CDK が no-op の場合は context だけ確認し、
tarball 配備のみが走ります (冪等)。

| 更新対象 | コマンド (`cd app/infra` 後) |
|---|---|
| 3 サービス全部再デプロイ | `bash deploy.sh --base-stack-name neuron-ws -r sa-east-1` |
| API のみ | `bash deploy.sh --base-stack-name neuron-ws -r sa-east-1 --skip-frontend-deploy --skip-stream-deploy` |
| Frontend のみ | `bash deploy.sh --base-stack-name neuron-ws -r sa-east-1 --skip-api-deploy --skip-stream-deploy` |
| Frontend のみ (build スキップ) | 上記に `--frontend-no-build` を追加 |
| Stream のみ | `bash deploy.sh --base-stack-name neuron-ws -r sa-east-1 --skip-api-deploy --skip-frontend-deploy` |
| 全 CDK のみ流す (SSM 配備なし) | `bash deploy.sh ... --skip-api-deploy --skip-frontend-deploy --skip-stream-deploy` |

> `--skip-*-deploy` は **CDK は流すが tarball 配備をスキップ** します (IAM / TG / rule の更新のみ反映したい場合に使用)。
> `--skip-*` は **CDK ごと touch しない** ので、stack を出さない時に使ってください。

---

### 3.3 全停止 / 破棄

```bash
# アプリ層 (依存逆順で消える)
cd <repo>/samples/voice-image-edit/app/infra
bash deploy.sh --base-stack-name neuron-ws -r sa-east-1 --destroy

# 基盤層 (frontend → alb → cognito → ec2 → efs の順で消える)
cd <repo>/setup/single-node/scripts
bash deploy.sh -r sa-east-1 --stack-name neuron-ws --destroy
```

---

## 4. トラブルシュート

### 4.1 `[NG] AlbArn is empty`

`app/infra/deploy.sh` 実行時に出る場合は `--base-stack-name` の値が間違っています。
`aws cloudformation list-stacks --query 'StackSummaries[?contains(StackName,\`-alb\`)]'`
で実在する基盤 ALB スタック名を確認 (`neuron-ws-alb` 等)。

### 4.2 Task Runner が "Already completed" で何もしない

`/tmp/task-state-<instance-id>.json` がローカルにキャッシュされています。
冪等再実行したい時:

```bash
rm -f /tmp/task-state-<instance-id>.json
```

その後 `run-tasks.sh` をもう一度実行。

### 4.3 `/api/edit/asr` を直接 fetch すると Cognito にリダイレクトされる

CloudFront Function (`viewer-request`) が `cf_session` cookie を要求します。
ブラウザでまず CloudFront ドメインにアクセスして Cognito Hosted UI にログイン → `/edit` を
表示してから fetch してください (cookie がセットされる)。

### 4.4 Bedrock Transcribe Streaming で `asyncio.run() cannot be called from a running event loop`

P13 で修正済み (`backend/api/app.py` を `asyncio.to_thread(engine.invoke, req)` に変更)。
古い tarball が EC2 に乗ったままなら §3.2 で再配備。

### 4.5 ALB rule 1000 (code-server catch-all) が voice-image-edit より優先される?

priority 数値が小さい方が強いので 100/150/200 < 1000 で voice-image-edit の方が勝ちます。
逆順を疑った時は:

```bash
aws elbv2 describe-rules --listener-arn <listener-arn> \
  --query 'Rules[].{Pri:Priority,Cond:Conditions[].Field,Tgt:Actions[0].TargetGroupArn}'
```

### 4.6 EC2 が再起動しても EFS / NEFF キャッシュが残るか

`neuron-ws-efs` は `RemovalPolicy.RETAIN`、Spot 再収容でも EFS は別ライフサイクル。
NFS ingress は `setup/single-node/scripts/deploy.sh` が冪等に再付与します。

---

## 5. ファイル参照早見表

| 役割 | パス |
|---|---|
| 基盤 CDK エントリ | `<repo>/setup/single-node/cdk/bin/app.ts` |
| 基盤 EC2 stack | `<repo>/setup/single-node/cdk/lib/torch-neuron-stack.ts` |
| 基盤 ALB stack | `<repo>/setup/single-node/cdk/lib/alb-backend-stack.ts` |
| 基盤 Cognito | `<repo>/setup/single-node/cdk/lib/cognito-operator-stack.ts` |
| 基盤 EFS | `<repo>/setup/single-node/cdk/lib/efs-persistence-stack.ts` |
| 基盤 CloudFront | `<repo>/setup/single-node/cdk/lib/cloudfront-frontend-stack.ts` |
| 基盤 deploy.sh | `<repo>/setup/single-node/scripts/deploy.sh` |
| 汎用 Task Runner | `<repo>/setup/single-node/scripts/run-tasks.sh` |
| アプリ CDK エントリ | `<repo>/samples/voice-image-edit/app/infra/bin/app.ts` |
| ApiStack | `<repo>/samples/voice-image-edit/app/infra/lib/api-stack.ts` |
| StreamStack | `<repo>/samples/voice-image-edit/app/infra/lib/stream-stack.ts` |
| FrontendStack | `<repo>/samples/voice-image-edit/app/infra/lib/frontend-stack.ts` |
| アプリ deploy.sh | `<repo>/samples/voice-image-edit/app/infra/deploy.sh` |
| API task | `<repo>/samples/voice-image-edit/app/infra/tasks/voice-image-edit-api.json` |
| Stream task | `<repo>/samples/voice-image-edit/app/infra/tasks/voice-image-edit-stream.json` |
| Frontend task | `<repo>/samples/voice-image-edit/app/infra/tasks/voice-image-edit-frontend.json` |
| Frontend コード | `<repo>/samples/voice-image-edit/app/frontend/` |
| API コード | `<repo>/samples/voice-image-edit/app/backend/api/` |
| Stream コード | `<repo>/samples/voice-image-edit/app/backend/stream/` |

---

## 6. 設計上の主要決定 (要点)

- **基盤とアプリの完全分離**: アプリ層は基盤 CFN Outputs と describe-* のみで成立し、
  基盤側のテンプレート差分を一切出さない (IAM Role への権限追加は `addToPrincipalPolicy`)
- **ALB rule の防御は二重**: path 条件 + `X-Origin-Verify` ヘッダ完全一致。CloudFront を
  迂回した直叩きは default action 403 で落ちる
- **EDIT 結果は presigned S3 URL**: SSE 経路に base64 が乗ると数 MB を超えるため、
  Nova Canvas 出力 PNG は 1 日 expire の S3 に置いて URL だけフロントへ返す
- **secret 値の扱い**: `OriginVerifySecret` も `HmacSecret` も Secrets Manager 管理。
  CDK synth 時にだけ `unsafeUnwrap()` して inline、CFN テンプレート上は値が出ないが
  drift 検知に乗る (rotation するなら secret 更新 + 両 stack 再 deploy)
- **systemd の冪等配備**: tarball の clean 展開 → venv 再生成 → unit 再 install →
  daemon-reload → restart → health-check が 1 つの JSON に閉じる
- **直接 SSH 禁止**: 全リモート操作は JSON Task 経由 (Task Runner 設計ルール準拠)
