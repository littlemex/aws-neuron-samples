# Voice-driven Image Edit Demo on Trainium2

trn2.48xlarge 上で 3 モデル (Qwen3-VL-8B-Thinking / Qwen-Image-Edit / Whisper-large-v3) を Docker なしで直接起動し、「音声で画像を編集する」 4 段パイプラインをバックエンドだけで完結検証するためのサンプルです。

## ディレクトリ設計

3 モデルは **疎結合** で配置されており、各モデルは単独でビルド・起動・テストできます。
3 モデルを束ねた一撃起動 / 連鎖 E2E テスト / EFS 永続化 のスクリプト群がこの `voice-image-edit/` です。

```
samples/
├── models/                              # モデル単体 (それぞれ独立)
│   ├── qwen3-vl/                        # Qwen3-VL-8B-Thinking (TP=16, NC 0-15, :8090)
│   │   ├── start.sh                     # 個別起動
│   │   ├── test.sh                      # 個別動作テスト
│   │   └── logs/                        # (起動後生成)
│   ├── qwen-image-edit/                 # Qwen-Image-Edit (TP=8, NC 16-23, :8081)
│   │   ├── start.sh
│   │   ├── test.sh
│   │   └── logs/
│   └── whisper/                         # Whisper-large-v3 (TP=1, NC 48, :8765)
│       ├── start.sh
│       ├── test.sh
│       ├── prepare_sample_ja_wav.sh    # 日本語サンプル wav 生成 (gTTS)
│       └── logs/
└── voice-image-edit/                    # 3 モデルを束ねるマージ層
    ├── start_all.sh                     # 3 モデル一撃起動 (内部で各 models/<name>/start.sh)
    ├── stop_all.sh                      # 3 モデル一撃停止
    ├── status.sh                        # ポート / プロセス / /health 一覧
    ├── test_all.sh                      # 3 モデル個別テスト一括 (内部で各 models/<name>/test.sh)
    ├── demo/
    │   ├── demo_e2e.sh                  # Whisper -> Qwen3-VL -> Qwen-Image-Edit -> Qwen3-VL の 4 段
    │   └── README.md
    └── efs/                             # Capacity Block terminate 対策
        ├── efs_paths.sh                 # 共通パス定義
        ├── backup_to_efs.sh             # /models, compiled_models, neuron-cache を EFS に保全
        ├── restore_from_efs.sh          # 復元
        └── README.md
```

## このサンプルが提供する範囲

| 含まれるもの | 含まれないもの |
|---|---|
| 3 モデル一撃起動 / 停止 / 状態確認 | モデルのサーバ実装 (FastAPI など) |
| NeuronCore 配置 (TP=16/8/1) のデフォルト値 | モデルの compile スクリプト |
| 個別動作テスト + 4 段 E2E テスト | UI / フロントエンド |
| EFS バックアップ・復元 (Capacity Block terminate 対策) | デプロイ用 CDK / Terraform |
| 日本語対応ヘルパー (gTTS で wav 生成 / hallucination 抑制) | Cognito / ALB / CloudFront 設定 |

各モデルのサーバ実装本体 (Qwen-Image-Edit 用の `serve.py`、Whisper 用の `whisper_server.py` など) は別途用意する必要があります。`SERVE_PY=...` / `SERVER_PY=...` 環境変数 / コマンドライン引数で絶対パスを指定するか、各モデルディレクトリに同名ファイルを置いてください。

Docker を**使わず**、trn2.48xlarge の DLAMI に同梱されている Neuron 仮想環境 (`/opt/aws_neuronx_venv_*`) と precompile 済みモデルを直接動かす最小構成です。

## 使い方

### モデル単体での起動・テスト (疎結合)

各モデルは単独で完結します:

```bash
# Qwen3-VL のみ
bash samples/models/qwen3-vl/start.sh
bash samples/models/qwen3-vl/test.sh

# Qwen-Image-Edit のみ
bash samples/models/qwen-image-edit/start.sh
bash samples/models/qwen-image-edit/test.sh

# Whisper のみ
bash samples/models/whisper/prepare_sample_ja_wav.sh   # 日本語 wav 生成 (1 回)
bash samples/models/whisper/start.sh
bash samples/models/whisper/test.sh
```

### 3 モデルまとめて起動・テスト (マージ層)

`voice-image-edit/` から束ねて操作します:

```bash
cd samples/voice-image-edit

# 全モデルをデフォルトポートで起動
bash start_all.sh

# ポート指定 (Qwen3=18090, Qwen-Image-Edit=18081, Whisper=18765)
bash start_all.sh --qwen3-port 18090 --vton-port 18081 --whisper-port 18765

# 一撃テスト (内部で ../models/<name>/test.sh を呼ぶ)
bash test_all.sh

# 停止
bash stop_all.sh

# 稼働確認
bash status.sh
```

## 日本語対応に関する注記

- **Qwen3-VL-8B-Thinking**: 学習時から日本語対応。プロンプトで日本語指示を入れれば日本語応答する。
- **Qwen-Image-Edit**: 多言語プロンプト対応。日本語プロンプト「赤いドレスに変更して」等で動作する。
- **Whisper-large-v3**: 多言語認識対応だが、`whisper_server.py` の generate 呼び出しが `language="en"` ハードコードのため、`WHISPER_LANGUAGE=ja` で日本語固定 / `WHISPER_LANGUAGE=auto` で自動検出できるよう **`models/whisper/start.sh` が起動時に自動パッチ** を当てます。
- 日本語認識のサンプル wav は `models/whisper/prepare_sample_ja_wav.sh` で生成します (gTTS → 失敗時 transformers `facebook/mms-tts-jpn` にフォールバック)。生成された `models/whisper/_assets/sample_ja.wav` は `models/whisper/test.sh` が自動的に拾います。

> 参考: gTTS で日本語音声を生成して Whisper に流す方式は
> [Zenn: OpenAI Whisper と NxD Inference による日本語音声認識](https://zenn.dev/tosshi/articles/f6c49165c90e6d) に従っています。

## Capacity Block terminate 対策 (EFS 永続化)

Capacity Block (CB) インスタンスは終了で `/models/`、`/opt/dlami/nvme/compiled_models/`、`/var/tmp/neuron-compile-cache/` がすべて消えます。
3 モデルが動いている状態で **必ず** EFS バックアップを取ってください:

```bash
bash efs/backup_to_efs.sh                # 3 種類すべて EFS へ rsync
bash efs/backup_to_efs.sh models         # /models のみ
bash efs/backup_to_efs.sh compiled       # compiled_models のみ
```

CB 再作成後の復元:

```bash
bash efs/restore_from_efs.sh             # 3 種類すべて ephemeral へ書き戻し
bash start_all.sh                        # 復元後にサーバー起動
```

詳細は `efs/README.md` を参照。

## demo E2E (3 モデル連携検証)

UI なしで 3 モデルがバックエンドで連携することを確認する e2e テストです。
パイプラインは Whisper (音声→指示) → Qwen3-VL (指示+画像→編集プロンプト) → Qwen-Image-Edit (編集) → Qwen3-VL (after 画像レビュー) の 4 段:

```bash
bash start_all.sh                                        # 3 サーバー起動
bash ../models/whisper/prepare_sample_ja_wav.sh          # 1 度だけ
bash demo/demo_e2e.sh                                    # 4 段パイプライン実行
```

詳細は `demo/README.md` を参照。

## NeuronCore 配置 (trn2.48xlarge: 64 cores)

| モデル | TP | NeuronCore | Port | ディレクトリ |
|---|---|---|---|---|
| Qwen3-VL-8B-Thinking | 16 | 0-15 | 8090 | `samples/models/qwen3-vl/` |
| Qwen-Image-Edit | 8 | 16-23 | 8081 | `samples/models/qwen-image-edit/` |
| Whisper-large-v3 | 1 | 48 | 8765 | `samples/models/whisper/` |

合計 25/64 cores 使用。残り 39 cores は将来の拡張用余裕。
