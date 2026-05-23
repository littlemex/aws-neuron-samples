# EFS Persistence (CB terminate 対策)

CB (Capacity Block) インスタンスは終了時に **ephemeral storage** が消えます。
具体的には以下:

| パス | 中身 | 終了で消える? |
|---|---|---|
| `/models/` | Qwen3-VL-8B-Thinking, Whisper-large-v3 などの HF/ Neuron weights | はい |
| `/opt/dlami/nvme/compiled_models/` | Qwen-Image-Edit の Neuron compile artifacts | はい |
| `/var/tmp/neuron-compile-cache/` | NEURON_COMPILE_CACHE_URL のキャッシュ | はい |
| `${EFS_ROOT}` (例: `/mnt/efs/voice-image-edit`) | EFS マウント (永続) | **いいえ** |

このディレクトリにある 3 本のスクリプトで、ephemeral と EFS の同期を取ります。

## パス定義

`efs_paths.sh` を `source` すると以下の env が定義されます。

| 変数 | デフォルト |
|---|---|
| `EFS_ROOT` | `/mnt/efs/voice-image-edit` (環境に合わせて override) |
| `EFS_BACKUP` | `${EFS_ROOT}/efs-backup` |
| `LOCAL_MODELS` | `/models` |
| `LOCAL_COMPILED` | `/opt/dlami/nvme/compiled_models` |
| `LOCAL_NEURON_CACHE` | `/var/tmp/neuron-compile-cache` |
| `EFS_MODELS` | `${EFS_BACKUP}/models` |
| `EFS_COMPILED` | `${EFS_BACKUP}/compiled_models` |
| `EFS_NEURON_CACHE` | `${EFS_BACKUP}/neuron-cache` |

## 使い方

### 通常運用 (動作確認できた状態で実行)

```bash
bash efs/backup_to_efs.sh             # 3 種類すべて EFS へ
bash efs/backup_to_efs.sh models      # 個別指定も可
bash efs/backup_to_efs.sh compiled
bash efs/backup_to_efs.sh cache
```

サーバー停止中である必要はありません。`rsync -aH --delete` で差分だけ転送します。

### CB 再作成後の復元

```bash
bash efs/restore_from_efs.sh                    # 3 種類すべて ephemeral へ
bash efs/restore_from_efs.sh models compiled    # 必要なものだけ
```

復元が終わってから `bash start_all.sh` で 3 サーバーを起動します。

## 注意

- EFS は遅いので、**実行時の読み出しは ephemeral からが正解**。EFS は「永続バックアップ」として使う。
- Qwen-Image-Edit の `compiled_models` は数十 GB あるので初回バックアップは時間がかかる。
- `--delete` を使っているため、ephemeral 側で削除したファイルは EFS 側からも消える。これは意図的 (「ephemeral が source of truth」)。
