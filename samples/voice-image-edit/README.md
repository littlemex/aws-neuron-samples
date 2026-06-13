# Voice-driven Image Edit Demo

「音声で画像を編集する」 UI / API / インフラ をまとめたデモアプリ。
3 つの ML スロット (ASR / VLM / EDIT) を **Bedrock 系** と **自前サービング (Trainium 等)** で切替可能な抽象化レイヤを介して動かします。

| スロット | 役割 | Bedrock 実装 | 自前サービング実装 |
|---|---|---|---|
| **ASR** | 音声 → テキスト指示 | Amazon Transcribe Streaming, Bedrock Nova Sonic | Whisper-large-v3 (Neuron) |
| **VLM** | 指示 + 画像 → 編集プロンプト / after 画像レビュー | Claude Sonnet, Nova Pro, Nova Lite | Qwen3-VL-8B-Instruct (Neuron) |
| **EDIT** | 画像 + プロンプト → 編集後画像 | Amazon Nova Canvas, Dummy (UI 配線確認) | Qwen-Image-Edit (Neuron) |

UI の `/manage` ページで **スロット ✕ 実装** を選び、`/edit` ページで音声指示 → 画像編集を実行します。
基盤インフラ (CloudFront / ALB / Cognito / EFS / EC2) は `setup/single-node/` 側に集約済みです。

## ディレクトリ構成

```
samples/voice-image-edit/
├── README.md                                # 本ファイル
└── app/
    ├── README.md                            # 二段デプロイの詳細
    ├── docs/PROJECT_STATUS.md
    ├── infra/                               # CDK + 一撃 deploy script
    │   ├── deploy.sh                        # ALB に edit-api Lambda + path rule を後付け
    │   ├── bin/app.ts
    │   └── lib/edit-api-stack.ts
    ├── backend/edit-api/                    # ALB Lambda Target (Python 3.12)
    │   ├── lambda_function.py               # /api/edit/{health,engines,asr,vlm,edit}
    │   ├── contracts.py                     # AsrRequest / VlmRequest / EditRequest 共通契約
    │   └── engines/
    │       ├── asr/{base,bedrock,trainium}.py
    │       ├── vlm/{base,bedrock,trainium}.py
    │       └── edit/{base,dummy,bedrock,trainium}.py
    └── frontend/                            # Next.js 14 standalone (App Router)
        └── src/app/
            ├── edit/page.tsx                # 音声指示 → 画像編集
            └── manage/page.tsx              # スロット別エンジン切替
```

## 抽象化の原則

3 スロットそれぞれに `<Slot>Request → <Slot>Response | EngineError` の単一契約があり、
新しい実装を追加するときは `engines/<slot>/<impl>.py` を作って `engines/<slot>/__init__.py` の registry に 1 行加えるだけで済む。

UI 側は localStorage に `{asr, vlm, edit}` の選択を保持し、API リクエストの `engines` フィールドに載せて送る。
Lambda はそれを受けて registry から実装を解決する。リクエストごとに違う実装を選べるため、
**Bedrock のみで E2E** / **自前サービングのみで E2E** / **混合 (例: ASR=Bedrock + EDIT=Trainium)** いずれも UI から確認できる。

## デプロイ

二段構成。基盤と本サンプルのアプリ層は完全独立で、本サンプル側は基盤の中身を一切前提しない。

1. **基盤** (CloudFront + Internal ALB + Cognito + EFS + EC2): `setup/single-node/scripts/deploy.sh` 一撃
2. **アプリ層** (edit-api Lambda + ALB rule): `samples/voice-image-edit/app/infra/deploy.sh` 一撃

詳細・引数・destroy 手順は `app/README.md` を参照。

## 自前サービング側のモデルサーバ

Trainium / GPU で 3 モデルを自前で立てる場合、各モデルサーバの実装本体 (Whisper の WS サーバ、Qwen3-VL の OpenAI 互換 HTTP サーバ、Qwen-Image-Edit の `serve.py`) は別途用意してください。
本サンプルが持つのは **Lambda からそれらに HTTP/WS で proxy する薄いクライアント** だけです。

各 trainium 実装は環境変数で接続先を受け取ります:

| 環境変数 | 用途 | 例 |
|---|---|---|
| `TRAINIUM_ASR_URL` | Whisper サーバの HTTP `/transcribe` endpoint | `http://internal-...:8765/transcribe` |
| `TRAINIUM_VLM_URL` | Qwen3-VL の OpenAI 互換 endpoint | `http://internal-...:8090/v1/chat/completions` |
| `TRAINIUM_EDIT_URL` | Qwen-Image-Edit の `/edit` endpoint | `http://internal-...:8081/edit` |

`app/infra/deploy.sh` の `--trainium-asr-url` / `--trainium-vlm-url` / `--trainium-edit-url` で context 経由に注入できる。

## 動作確認の最短経路 (Bedrock のみ)

```bash
# 1) 基盤 (CloudFront / ALB / Cognito / EFS / EC2) を一撃で立てる
AWS_PROFILE=claude-code bash setup/single-node/scripts/deploy.sh \
  -r sa-east-1 --use-spot --full --install-claude-code \
  --stack-name neuron-code-server \
  --operator-email you@example.com --operator-password 'YourS3cret!Pass'

# 2) アプリ層 (edit-api Lambda + /api/edit/* rule) を一撃で乗せる
AWS_PROFILE=claude-code bash samples/voice-image-edit/app/infra/deploy.sh \
  --base-stack-name neuron-code-server -r sa-east-1 \
  --bedrock-region us-east-1

# 3) CloudFront ドメインで /manage を開き、3 スロット全部を Bedrock 系に設定
# 4) /edit に移動して音声入力 → 画像編集を実行
```
