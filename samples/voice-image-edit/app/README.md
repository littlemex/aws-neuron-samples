# voice-image-edit / app

「音声で画像を編集する」 UI 層 + API 層 + ストリーミング層 + インフラ層を束ねたディレクトリ。
3 つの ML スロット (ASR / VLM / EDIT) を **Bedrock 系** と **自前サービング (Trainium 等)** に切替可能な抽象化レイヤを介して動かす。
基盤 (CloudFront / ALB / Cognito / EFS / EC2) は `setup/single-node/` 側に集約済みで、本ディレクトリは触らない。

```
app/
├── infra/                                  # CDK (TypeScript) + 一撃 deploy script
│   ├── deploy.sh                           # 既存 ALB に api/frontend/stream rule + Target を後付け
│   ├── bin/app.ts
│   ├── lib/
│   │   ├── api-stack.ts                    # /api/edit/* (EC2:8801) + EditResultBucket + IAM
│   │   ├── frontend-stack.ts               # /, /edit*, /manage*, /_next/* (EC2:3000)
│   │   └── stream-stack.ts                 # /stream/* (EC2:8800)
│   └── tasks/                              # Task Runner (SSM) JSON 定義
│       ├── voice-image-edit-api.json       # systemd voice-image-edit-api.service:8801
│       ├── voice-image-edit-frontend.json  # systemd voice-image-edit-frontend.service:3000
│       └── voice-image-edit-stream.json    # systemd voice-image-edit-stream.service:8800
│
├── backend/
│   ├── api/                                # FastAPI/uvicorn (Python 3.10+, EC2 上で systemd 常駐)
│   │   ├── app.py                          # /api/edit/{health,engines,asr,vlm,edit}
│   │   ├── contracts.py                    # AsrRequest / VlmRequest / EditRequest 共通契約
│   │   └── engines/
│   │       ├── asr/{base,bedrock,trainium}.py
│   │       ├── vlm/{base,bedrock,trainium}.py
│   │       └── edit/{base,dummy,bedrock,trainium}.py
│   └── stream/                             # FastAPI/uvicorn (SSE)
│       └── app.py                          # /stream/{health,echo,pipeline}
│
└── frontend/                               # Next.js 14 standalone (App Router + Tailwind)
    └── src/app/
        ├── edit/page.tsx                   # 音声指示 → 画像編集 (SSE 4 段パイプライン)
        └── manage/page.tsx                 # スロット ✕ 実装の切替 UI
```

## 抽象化レイヤの考え方

3 スロットそれぞれに `<Slot>Request → <Slot>Response | EngineError` の単一契約があり、
新しい実装を追加する時は `engines/<slot>/<impl>.py` を作って `engines/<slot>/__init__.py` の registry に 1 行加えるだけ。

| スロット | 契約 | 失敗時 |
|---|---|---|
| ASR | `AsrRequest{audio_b64, mime_type, language?} → AsrResponse{text, segments?, metadata}` | `EngineError(code, message, retryable, provider_detail)` |
| VLM | `VlmRequest{image_b64, prompt, mode (instruction\|review)} → VlmResponse{text, metadata}` | 同上 |
| EDIT | `EditRequest{image_b64, prompt, options} → EditResponse{image_url, image_format, image_bytes, metadata}` | 同上 |

UI 側は `localStorage` に `{asr, vlm, edit}` の選択を保持し、API リクエストの `engines` フィールドに載せて送る。
api backend はそれを受けて registry から実装を解決する。リクエストごとに違う実装を選べるため、
**Bedrock のみで E2E** / **自前サービングのみで E2E** / **混合 (例: ASR=Bedrock + EDIT=Trainium)** いずれも UI から確認できる。

EDIT の出力 PNG は短命 S3 bucket に PUT し、presigned URL (1 日 expire) として返す。
inline base64 で返さない理由は、SSE 経路の payload 肥大と CloudFront/ALB 上の buffering 回避。

## エンジン候補 (実装予定)

| スロット | Bedrock 系 | 自前サービング系 |
|---|---|---|
| **ASR** | Amazon Transcribe Streaming, Bedrock Nova Sonic | Whisper-large-v3 (Neuron) |
| **VLM** | Claude Sonnet, Nova Pro, Nova Lite | Qwen3-VL-8B-Instruct (Neuron) |
| **EDIT** | Amazon Nova Canvas, Dummy (UI 配線確認) | Qwen-Image-Edit (Neuron) |

Bedrock 系は **特定モデルに依存しない** ように設計する。同じスロット内で複数モデルを `engines/<slot>/__init__.py` に登録しておき、`/manage` ページから選び替えるだけで切り替わる。

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

EC2 1 台に 3 つの systemd unit を同居させる構成。`/api/edit/*` の Lambda Target 退役 (P10) は、
ALB Lambda Target の 1 MB request/response body 上限が画像 pipeline (Nova Canvas 出力 1.6 MB+)
に構造的に合わなかったため。

## デプロイ (二段階一撃方式)

このサンプルは「基盤 1 撃 + アプリ 1 撃」の二段階で完了する。各段は完全に独立しており、
`app/infra/deploy.sh` は基盤側の中身を一切前提しない。

### Stage 1: 基盤 (本サンプルでは触らない)

CloudFront / Internal ALB / Cognito / EFS / EC2 は `setup/single-node/scripts/deploy.sh` 一撃。
詳細は `setup/single-node/README.md` 参照。アプリ層は基盤の outputs (ALB ARN 等) を CloudFormation export 経由でしか参照しない。

### Stage 2: voice-image-edit のアプリ層を乗せる

`infra/deploy.sh` は `--base-stack-name` で基盤 outputs を auto-resolve する。
ALB / VpcId / EC2 InstanceId / SecurityGroupId / IAM Role 名は `aws elbv2/ec2/iam describe-*` で逆引きする。

```bash
AWS_PROFILE=claude-code bash samples/voice-image-edit/app/infra/deploy.sh \
    --base-stack-name neuron-code-server \
    -r sa-east-1 \
    --bedrock-region us-east-1
```

このコマンド 1 つで:

1. CDK bootstrap bucket に api/frontend/stream の各 tarball をアップロードして presigned URL を発行
2. `cdk deploy` で `VoiceImageEditApiStack` / `VoiceImageEditFrontendStack` / `VoiceImageEditStreamStack` を立てる
   (ALB rule / TG / EC2 SG ingress / Bedrock + Transcribe + S3 IAM 付与 / EditResultBucket)
3. SSM Run Command (`setup/single-node/scripts/run-tasks.sh`) で各 systemd unit を冪等に再起動
   - `voice-image-edit-api.service` (port 8801, FastAPI/uvicorn)
   - `voice-image-edit-frontend.service` (port 3000, Next.js)
   - `voice-image-edit-stream.service` (port 8800, FastAPI/uvicorn, SSE)

### 自前サービング側の URL を渡す

3 モデルを Trainium / GPU で自前で立てる場合、各モデルサーバの実装本体は別途用意し、api backend には接続先だけを渡す:

```bash
AWS_PROFILE=claude-code bash samples/voice-image-edit/app/infra/deploy.sh \
    --base-stack-name neuron-code-server \
    --trainium-asr-url  ws://internal-...:8765/whisper-neuron/ws \
    --trainium-vlm-url  http://internal-...:8090/v1/chat/completions \
    --trainium-edit-url http://internal-...:8081/edit
```

UI 側は `/manage` ページで各スロットの実装を選び替えるだけ。リクエストごとに有効化されるため、再デプロイは不要。

### destroy

```bash
# Stage 2: voice-image-edit のみ落とす
AWS_PROFILE=claude-code bash samples/voice-image-edit/app/infra/deploy.sh \
    --destroy --base-stack-name neuron-code-server -r sa-east-1
```

基盤側 (Stage 1) は `setup/single-node/scripts/deploy.sh --destroy` で別途落とす。

## 開発ループ

### Backend (api / stream)

```bash
cd app/backend/api
python3 -m pytest tests/ -q
```

各 engine は環境変数で接続先を受け取る (systemd Environment 経由で渡す):

| 環境変数 | 用途 |
|---|---|
| `BEDROCK_REGION` | Bedrock 呼び出し先 region |
| `EDIT_RESULT_BUCKET` | EDIT 出力 PNG の短命 S3 bucket 名 |
| `TRAINIUM_ASR_URL` | Whisper サーバの WS 入口 |
| `TRAINIUM_VLM_URL` | Qwen3-VL の OpenAI 互換 endpoint |
| `TRAINIUM_EDIT_URL` | Qwen-Image-Edit の `/edit` endpoint |

### Frontend

```bash
cd app/frontend
npm install
npm run dev   # http://localhost:3000/edit  /  /manage
```

ローカルでは `/api/edit/*` および `/stream/*` は ALB 越しに reach する必要があるため、`next.config.mjs` の `rewrites` に dev-time proxy を足すか、本番 CloudFront 経由でアクセスする。

## ハードコード禁止 / プロファイル統一

- すべての AWS 操作は `AWS_PROFILE=claude-code` 厳守
- リージョン・モデル ID・URL は context (CDK) または環境変数 (systemd) 経由で注入
- 自前サービング側の EC2 を直接いじる場合も SSM + Task Runner (`setup/single-node/scripts/run-tasks.sh`) 経由
