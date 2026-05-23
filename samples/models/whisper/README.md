# Whisper-large-v3 on Trainium2

Whisper-large-v3 (NxD Inference precompile 版) を trn2.48xlarge 上で起動・テストするサンプル。
他の 2 モデル (Qwen3-VL / Qwen-Image-Edit) とは独立して動作確認できます。

## 配置 (デフォルト)

| 項目 | 値 |
|---|---|
| TP | 1 |
| NeuronCore | 48 |
| Port | 8765 |
| Endpoint | WebSocket `ws://...:8765/whisper-neuron/ws`、`GET /whisper-neuron/health` |
| Venv | `/opt/aws_neuronx_venv_pytorch_2_9_nxd_inference` |
| Model dir | `/models/whisper-large-v3-neuron` |
| whisper_server.py | `${PWD}/whisper_server.py` (環境変数 `SERVER_PY` または `--server-py` で上書き可) |

## 日本語対応に関する注記

`whisper_server.py` は generate 呼び出しが `language="en"` でハードコードされています。
`start.sh` は **起動時に一度だけ** 以下のパッチを当てます:

- `WHISPER_LANGUAGE_ENV_PATCH` マーカーを挿入
- `WHISPER_LANGUAGE` 環境変数 (`ja` / `en` / `auto`) を読み取り
- `language="en"` を `language=WHISPER_LANGUAGE` に置換

すでにパッチ済みなら何もしません。

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

## 関連

3 モデル一括で起動・E2E するには `samples/voice-image-edit/` を参照。
