# Whisper-large-v3 on Trainium2

Whisper-large-v3 (Neuron torch_neuronx 事前コンパイル版) を trn2.48xlarge 上で起動・テストするサンプル。
他の 2 モデル (Qwen3-VL / Qwen-Image-Edit) とは独立して動作確認できます。

## 配置 (デフォルト)

| 項目 | 値 |
|---|---|
| TP | 1 |
| NeuronCore | 48 |
| Port | 8765 |
| Endpoint | HTTP `POST /transcribe`、 WebSocket `ws://...:8765/whisper-neuron/ws`、 `GET /health` (= `GET /whisper-neuron/health`) |
| Venv | `/opt/aws_neuronx_venv_pytorch_2_9_nxd_inference` |
| Model dir | `/models/whisper-large-v3-neuron` |
| whisper_server.py | `${PWD}/whisper_server.py` (環境変数 `SERVER_PY` または `--server-py` で上書き可) |
| compile_whisper.py | `${PWD}/compile_whisper.py` (1 回だけ走らせて Model dir に成果物を置く) |

## エンドポイント仕様

### `POST /transcribe` (voice-image-edit ASR contract)

- リクエスト: raw audio bytes を `application/octet-stream` で送る
- ヘッダ:
  - `X-Mime-Type` (例: `audio/pcm; rate=16000`、`audio/webm`、`audio/wav` 等)
  - `X-Sample-Rate` (raw PCM のときのみ必須)
  - `X-Language` (省略時は `WHISPER_LANGUAGE` env)
- レスポンス: `{"text": str, "segments": [{"start_ms", "end_ms", "text"}], "language": str, "duration_ms": int, "latency_ms": int}`

decode は `X-Mime-Type` が `pcm` を含む / `application/octet-stream` のとき raw PCM int16 として直接読み込み、
それ以外は `soundfile` (libsndfile) → `ffmpeg` フォールバックの順で試みます。 16 kHz 以外は線形補間でリサンプル。

### `GET /whisper-neuron/ws` (legacy live streaming)

旧 GPU デモと同じ live streaming 用。 16 kHz int16 mono PCM チャンクを WebSocket で送ると、
Silero VAD で speech 区間だけを transcribe して JSON で返す。 voice-image-edit 側からは使わない。

## 日本語対応

`whisper_server.py` は `WHISPER_LANGUAGE` env (`ja`|`en`|`auto`|`none`) をネイティブで解釈するため、
`start.sh` のパッチは no-op になります (互換性のためマーカー判定だけ残置)。 `auto`/`none` は generate に
`language=None` を渡して自動検出させます。

## Trainium 上での precompile

初回のみ Neuron 成果物を生成する必要があります。約 30 分かかるため、 systemd 起動とは別に走らせます。

```bash
# venv に必要パッケージを入れて、 一度だけコンパイル
source /opt/aws_neuronx_venv_pytorch_2_9_nxd_inference/bin/activate
pip install 'datasets<3' librosa soundfile
NEURON_RT_VISIBLE_CORES=48 NEURON_RT_NUM_CORES=1 \
  python compile_whisper.py \
    --model-id openai/whisper-large-v3 \
    --output-dir /models/whisper-large-v3-neuron \
    --batch-size 1 --max-dec-len 448 --skip-validation
```

`/models/whisper-large-v3-neuron/compile_metadata.json` と 3 つの `.pt` (encoder/decoder/proj) が
生成されたら完了。 `whisper_server.py` 起動時にこれらを読み込みます。

## 単体起動

```bash
bash start.sh                       # WHISPER_LANGUAGE=ja (デフォルト) で起動
bash start.sh --language auto       # 自動判定
SERVER_PY=/path/to/whisper_server.py bash start.sh
```

ログとピッドファイルは `./logs/whisper.log`、`./logs/whisper.pid` に出力されます。`LOG_DIR` 環境変数で上書き可能。

## 日本語サンプル wav の生成

`test.sh` の段階 3 (実音声認識) を動かすには、16kHz mono int16 の日本語 wav が必要です。
gTTS で生成するヘルパーを同梱しています:

```bash
bash prepare_sample_ja_wav.sh        # ./_assets/sample_ja.wav に生成 (1 回のみ)
TEXT='別のテキスト' bash prepare_sample_ja_wav.sh   # テキストを変える
FORCE=1 bash prepare_sample_ja_wav.sh                # 強制再生成
```

> 参考: gTTS で日本語音声を生成して Whisper に流す方式は
> [Zenn: OpenAI Whisper と NxD Inference による日本語音声認識](https://zenn.dev/tosshi/articles/f6c49165c90e6d) に従っています。

## 単体テスト

```bash
bash test.sh                          # /health + 合成 PCM (sin 波) + (あれば) sample_ja.wav を流す
bash test.sh --wav /path/to/your.wav  # 任意の 16kHz mono int16 wav を使う
```

`POST /transcribe` を curl で叩く例:

```bash
# 16 kHz mono int16 PCM を直接送る
curl -X POST "http://localhost:8765/transcribe" \
  -H "X-Mime-Type: audio/pcm" \
  -H "X-Sample-Rate: 16000" \
  -H "X-Language: ja" \
  --data-binary @sample_ja.pcm
```

## SSM Run Command 経由のデプロイ (Task Runner)

リモート EC2 にデプロイする場合は `tasks/` 配下の JSON を `setup/single-node/scripts/run-tasks.sh` で実行する:

| JSON | 役割 | 1 回だけか / 毎デプロイか |
|---|---|---|
| `tasks/whisper-precompile.json` | Neuron 成果物を `/models/whisper-large-v3-neuron` に生成 (約 30 分) | 1 回だけ (キャッシュ判定で skip) |
| `tasks/whisper-server.json` | `whisper_server.py` を `/opt/voice-image-edit/whisper-server` に展開し systemd で常駐 | デプロイのたびに |

`SERVER_TARBALL_URL` / `COMPILE_SCRIPT_URL` には presigned S3 URL を渡す。

## 関連

3 モデル一括で起動・E2E するには `samples/voice-image-edit/` を参照。
