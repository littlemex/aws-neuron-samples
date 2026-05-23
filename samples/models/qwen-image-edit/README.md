# Qwen-Image-Edit on Trainium2

Qwen-Image-Edit (Diffusers ベースの画像編集モデル) を NxD Inference で trn2.48xlarge 上で起動・テストするサンプル。
他の 2 モデル (Qwen3-VL / Whisper) とは独立して動作確認できます。

## 配置 (デフォルト)

| 項目 | 値 |
|---|---|
| TP | 8 |
| NeuronCore | 16-23 |
| Port | 8081 |
| Endpoint | `POST /infer` (multipart, 入力画像 + prompt) |
| Compiled artifacts | `/opt/dlami/nvme/compiled_models` |
| serve.py | `${PWD}/serve.py` (環境変数 `SERVE_PY` または `--serve-py` で上書き可) |

## 単体起動

`serve.py` (FastAPI など) は別途用意して、`SERVE_PY` 環境変数か `--serve-py` で絶対パスを指定するか、このディレクトリに配置してください。

```bash
SERVE_PY=/path/to/serve.py bash start.sh
bash start.sh --serve-py /path/to/serve.py --port 18081
bash start.sh --compiled-dir /path/to/compiled_models
```

ログとピッドファイルは `./logs/vton.log`、`./logs/vton.pid` に出力されます。`LOG_DIR` 環境変数で上書き可能。

## 単体テスト

`test.sh` は単色 PNG (256x256) をローカル合成し、日本語プロンプトで `/infer` に POST して PNG が返ることを確認します。

```bash
bash test.sh                     # 日本語プロンプトで画像編集 → PNG 検証
bash test.sh --port 18081
```

## 関連

3 モデル一括で起動・E2E するには `samples/voice-image-edit/` を参照。
