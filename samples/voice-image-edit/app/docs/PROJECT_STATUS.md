# voice-image-edit / app 実装状況

**最終更新**: 2026-05-26
**プロジェクト目的**: 音声で画像を編集するデモを E2E で動かす。3 スロット (ASR / VLM / EDIT) を **Bedrock 系** と **自前サービング (Trainium 等)** の双方で切替可能にし、UI の `/manage` ページから実装をスイッチできる状態にする。

## 総合進捗

### 実装方針

- 3 スロット (ASR / VLM / EDIT) それぞれに `<Slot>Request → <Slot>Response | EngineError` の単一契約。
- `engines/<slot>/<impl>.py` を追加し `engines/<slot>/__init__.py` に 1 行加えるだけで新実装を組み込める。
- UI 側は `localStorage` に `{asr, vlm, edit}` を保持し、リクエスト毎に implementation を解決する。
- Stage 1 (CloudFront / ALB / Cognito / EFS / EC2) は `setup/single-node/` 側に集約済み。本サンプルでは触らない。

### 実装ステータス

| レイヤ | 内容 | 状態 |
|---|---|---|
| infra (CDK) | ApiStack: ALB rule (priority 100) + IP TG (EC2:8801) + EditResultBucket + IAM 付与 | 完了 (P10) |
| infra (CDK) | FrontendStack: ALB rule (priority 200) + Instance TG (EC2:3000) | 完了 (P7) |
| infra (CDK) | StreamStack: ALB rule (priority 150) + IP TG (EC2:8800) | 完了 (P8) |
| infra (script) | `app/infra/deploy.sh` 一撃 voice-image-edit deploy (api/frontend/stream) | 完了 (P10) |
| infra (IAM) | EC2 instance role に `bedrock:InvokeModel`/`Converse`/`InvokeModelWithResponseStream` + `transcribe:StartStreamTranscription` + EditResultBucket grantPut/grantRead | 完了 (P10) |
| infra (Task Runner) | `infra/tasks/voice-image-edit-{api,frontend,stream}.json` | 完了 (P10) |
| backend (api) | `backend/api/app.py` (FastAPI/uvicorn :8801, systemd 常駐) | 完了 (P10) |
| backend (api) | `contracts.py` を AsrRequest / VlmRequest / EditRequest に分離 | 完了 (P1) |
| backend (api) | `engines/asr/{base,bedrock,trainium}.py` | 完了 (P2) |
| backend (api) | `engines/vlm/{base,bedrock,trainium}.py` | 完了 (P3) |
| backend (api) | `engines/edit/{base,dummy,bedrock,trainium}.py` (`bedrock_nova_canvas` は presigned S3 URL を返す) | 完了 (P7-F) |
| backend (api) | `requirements.txt`: fastapi/uvicorn/boto3/urllib3/amazon-transcribe (Pillow なし) | 完了 (P10) |
| backend (api) | tests/test_engines.py: contract + dummy + registry + bedrock/trainium guard + asr/vlm 詳細 | 完了 |
| backend (stream) | `backend/stream/app.py` (FastAPI/uvicorn :8800, SSE) | 完了 (P8/P9) |
| backend (stream) | `/stream/pipeline` で 4 段パイプラインを SSE 配信 | 完了 (P9) |
| backend (stream) | `requirements.txt`: fastapi/uvicorn/httpx (Pillow shrink hack revert) | 完了 (P10-F) |
| frontend | `/manage` ページ + `lib/engineConfig.ts` (localStorage) | 完了 (P4) |
| frontend | `/edit` ページを 4 段パイプライン (ASR → VLM 指示生成 → EDIT → VLM レビュー) に昇格 | 完了 (P5) |
| frontend | SSE 受信版 `/stream/pipeline` 配線 | 完了 (P9-C) |
| frontend | `lib/audio.ts` (PCM 16kHz mono int16 LE 変換) + `VoiceRecorder.tsx` 書き直し | 完了 (P2) |
| frontend | production build green (Next.js 14 standalone, EC2:3000 systemd) | 完了 (P7-C) |
| docs | README.md / app/README.md / PROJECT_STATUS.md を P10 (Lambda 退役) 前提に書き直し | 完了 (P10) |

### Stage 1 廃止項目

`setup/single-node/` 側に既に存在するため、本ディレクトリから削除済み:

- `samples/voice-image-edit/{start_all,stop_all,status,test_all}.sh` (trn2 モデル起動 wrapper)
- `samples/voice-image-edit/efs/` (EFS 永続化スクリプト群、`setup/single-node/cdk/lib/efs-persistence-stack.ts` で代替)
- `samples/voice-image-edit/demo/` (E2E demo wrapper)
- `samples/voice-image-edit/app/infra/setup/` (Task Runner、`setup/single-node/scripts/run-tasks.sh` で代替)

### P10 で削除/置換した項目

- `backend/edit-api/lambda_function.py` → `backend/api/app.py` (FastAPI ポート、Lambda handler は退役)
- `infra/lib/edit-api-stack.ts` (Lambda + ALB Lambda Target) → `infra/lib/api-stack.ts` (IP target on EC2:8801)
- `backend/stream/app.py` の Pillow shrink hack (vlm_review に渡す画像の縮小) を revert
  → ALB Lambda Target の 1 MB body 上限がなくなったため不要
- `infra/deploy.sh` の Lambda zip パッケージング (`pip install -t .build/`) も削除

## アーキテクチャ概要 (P10 以降)

```
Browser
  │
  ├─ /              (Next.js)
  ├─ /edit*         (Next.js)
  ├─ /manage*       (Next.js)
  ├─ /_next/*       (Next.js)
  ├─ /api/edit/*    (FastAPI/uvicorn)   ← P10 で Lambda 退役
  └─ /stream/*      (FastAPI/uvicorn, SSE)
        │
   CloudFront → Internal ALB
        │
        EC2 (single host, systemd)
        ├── voice-image-edit-frontend.service :3000
        ├── voice-image-edit-stream.service   :8800
        └── voice-image-edit-api.service      :8801
```

## 二段デプロイの不変条件

- Stage 1 と Stage 2 は **完全独立**。Stage 2 は基盤 deploy.sh の中身を一切前提しない。
  唯一の入力は `--base-stack-name <name>` (デフォルト `neuron-code-server`) 1 つだけ。
- Stage 2 は CFn Outputs (`<name>-alb` の AlbArn / AlbSecurityGroupId / OriginVerifySecretArn) と
  `aws elbv2/ec2/iam describe-*` (VpcId / ListenerArn / EC2 InstanceId / SG / IAM Role) のみで必要値を解決する。
- 3 つの systemd unit (api/frontend/stream) はすべて Task Runner JSON + SSM Run Command 経由で冪等にデプロイ。
- Tarball は CDK bootstrap bucket (`cdk-hnb659fds-assets-<account>-<region>`) に上げて 1800s presigned URL で EC2 に渡す (EC2 IAM に S3 不要)。

## エンジン抽象化の不変条件

- 各スロット契約は `backend/api/contracts.py` が単一情報源。
- `engines/<slot>/__init__.py` の `ENGINES` dict に 1 行追加するだけで新実装を registry に挟める。
- すべての engine 実装は `EngineError(code, message, retryable, provider_detail)` だけで失敗を表現する。
- 環境変数のみで接続先を受け取る (ハードコード禁止):
  - 共通: `BEDROCK_REGION` / `EDIT_RESULT_BUCKET` / `EDIT_RESULT_TTL_SECONDS` / `EDIT_RESULT_PREFIX`
  - 既定: `ASR_ENGINE_DEFAULT` / `VLM_ENGINE_DEFAULT` / `EDIT_ENGINE_DEFAULT`
  - Bedrock model ID: `BEDROCK_ASR_BACKEND` / `BEDROCK_CLAUDE_SONNET_MODEL_ID` / `BEDROCK_NOVA_PRO_MODEL_ID` / `BEDROCK_NOVA_LITE_MODEL_ID` / `BEDROCK_NOVA_CANVAS_MODEL_ID` / `BEDROCK_VLM_MODEL_ID` / `BEDROCK_EDIT_MODEL_ID`
  - Trainium 自前サービング URL: `TRAINIUM_ASR_URL` (Whisper) / `TRAINIUM_VLM_URL` (OpenAI 互換 chat/completions) / `TRAINIUM_EDIT_URL` (Qwen-Image-Edit `/edit`)

## Stage 2 deploy.sh の引数

```
# 3 スロット既定値
--asr-engine-default     bedrock_transcribe (default)
--vlm-engine-default     bedrock_nova_lite (default)
--edit-engine-default    bedrock_nova_canvas (default)

# Bedrock model ID 上書き
--bedrock-asr-backend          transcribe (default) | nova_sonic
--bedrock-claude-sonnet-model  anthropic.claude-3-5-sonnet-20241022-v2:0 (default)
--bedrock-nova-pro-model       amazon.nova-pro-v1:0 (default)
--bedrock-nova-lite-model      amazon.nova-lite-v1:0 (default)
--bedrock-edit-model           amazon.nova-canvas-v1:0 (default)

# Trainium 自前サービング URL (空ならエンジンは config_missing で 503 を返す)
--trainium-asr-url   http://internal-...:8000/transcribe
--trainium-vlm-url   http://internal-...:8090/v1/chat/completions
--trainium-edit-url  http://internal-...:8100/edit

# 個別 stack のスキップ
--skip-api / --skip-frontend / --skip-stream
--skip-api-deploy / --skip-frontend-deploy / --skip-stream-deploy   (CDK は実行するが SSM run-tasks をスキップ)
```

最小実行例:

```bash
# Stage 1 (基盤)
bash setup/single-node/scripts/deploy.sh \
  -r sa-east-1 --use-spot --full --install-claude-code \
  --stack-name neuron-code-server \
  --operator-email ... --operator-password ...

# Stage 2 (voice-image-edit)
bash samples/voice-image-edit/app/infra/deploy.sh \
  --base-stack-name neuron-code-server \
  --bedrock-region us-east-1
```

## チーム運用ルールの抜粋

- `AWS_PROFILE=claude-code` 厳守。他プロファイルの利用は禁止。
- ハードコード禁止。すべて context / 環境変数 / 引数経由で注入。
- 直接 SSH 禁止。EC2 操作は SSM + Task Runner JSON 経由 (`setup/single-node/scripts/run-tasks.sh`)。
- コミットはユーザー明示依頼まで実施しない (Co-Authored-By 禁止)。
- 企業名・個人名禁止 (匿名化)。

## 残タスク

- **P10 deploy + E2E**: ローカルから push 不可のため、ユーザー側で `bash samples/voice-image-edit/app/infra/deploy.sh --base-stack-name <name> --bedrock-region us-east-1` を実行し、CloudFront 経由で `/api/edit/health` / `/api/edit/engines` / `/edit` ページの 4 段パイプラインが EC2:8801 経由で通ることを確認する。旧 Lambda は CDK update で stack 名 `VoiceImageEditApiStack` の中身が完全に書き換わるため自動退役される (Lambda 関数 / 旧 ALB rule / 旧 TG はすべて削除)。
- 将来: Bedrock Nova Sonic ASR (双方向 streaming) / Trainium 3 サービングのスタンドアップ。
