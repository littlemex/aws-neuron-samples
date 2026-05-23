# Trainium2 サンプルモデル群

trn2.48xlarge 上で起動・テストできる単体モデルサンプルを集めたディレクトリです。
各モデルは **完全に疎結合** で、それぞれ単独で `start.sh` / `test.sh` を実行して動作確認できます。

| モデル | TP | NeuronCore | Port | ディレクトリ |
|---|---|---|---|---|
| Qwen3-VL-8B-Thinking | 16 | 0-15 | 8090 | `qwen3-vl/` |
| Qwen-Image-Edit | 8 | 16-23 | 8081 | `qwen-image-edit/` |
| Whisper-large-v3 | 1 | 48 | 8765 | `whisper/` |

3 モデル一括起動・連鎖 E2E テスト・EFS バックアップは `samples/voice-image-edit/` を参照。

## 共通の前提

- Docker を**使わず**、DLAMI 同梱の Neuron 仮想環境 (`/opt/aws_neuronx_venv_*`) を直接使用
- 各 `start.sh` は同じポートで listening 中なら **skip** する (冪等)
- 各 `start.sh` のログ・PID は `./logs/<model>.{log,pid}` (`LOG_DIR` で上書き可)
- 各モデルのサーバ実装本体 (`serve.py`, `whisper_server.py` 等) は別途用意し、環境変数または引数で絶対パスを指定する設計
