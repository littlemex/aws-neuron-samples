# Qwen3-VL-8B-Instruct on Trainium2

Qwen3-VL-8B-Instruct を vLLM + NxD Inference で trn2.48xlarge 上で起動・テストするサンプル。
他の 2 モデル (Qwen-Image-Edit / Whisper) とは独立して動作確認できます。

## 配置 (デフォルト)

| 項目 | 値 |
|---|---|
| TP | 16 |
| NeuronCore | 0-15 |
| Port | 8090 |
| Endpoint | OpenAI 互換 (`/v1/chat/completions`) |
| Venv | `/opt/aws_neuronx_venv_pytorch_inference_vllm_0_16` |
| Model dir | `/models/Qwen3-VL-8B-Instruct` (環境変数で上書き可) |

## 単体起動

```bash
bash start.sh                    # デフォルト設定で起動
bash start.sh --port 18090       # 別ポート
MODEL_DIR=/path/to/model bash start.sh
```

ログとピッドファイルは `./logs/qwen3.log`、`./logs/qwen3.pid` に出力されます。`LOG_DIR` 環境変数で上書き可能。

## 単体テスト

```bash
bash test.sh                     # /health + 日本語チャット + 画像理解 (日本語応答 PASS/FAIL)
bash test.sh --port 18090
```

## 関連

3 モデル一括で起動・E2E するには `samples/voice-image-edit/` を参照。
