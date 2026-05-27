# 永続化と Spot Recovery 設計

voice-image-edit を Spot や CodeBuild Capacity Reservation 上で運用するときの、
**model キャッシュ + compile 成果物 + サーバ source を EFS に逃がす**ための設計。

新しいインスタンスが立ち上がったときに、HF download や Neuron compile を
やり直さずにすぐサービングを再開できることを目的とします。

## 何を永続化するのか

| データ | 容量 | 永続化先 | 理由 |
|---|---|---|---|
| Neuron NEFF compile cache | ~数 GB | EFS (既存: `/mnt/efs/neuron-workspace/neuron-compile-cache`) | Neuron compile を 50%-100% 短縮 |
| HF model snapshots (Qwen-Image-Edit, Qwen3-VL) | ~110 GB | EFS | Hugging Face からの再 download (~30 min) を回避 |
| Whisper compiled `.pt` + tokenizer | 13 GB | EFS | encoder/decoder/proj の compile を skip |
| Qwen-Image-Edit V3 CFG compiled artifacts | ~80 GB | EFS | VAE + Transformer + Vision Encoder + Language Model の compile (~60 min) を skip |
| Qwen3-VL compiled neuron model | ~10 GB | EFS | warmup を skip |
| voice-image-edit サーバ source (serve.py 等) | ~10 MB | EFS | tarball 再展開を skip |

EFS は `setup/single-node/cdk/lib/efs-persistence-stack.ts` で
`RemovalPolicy.RETAIN` 指定なので、 EC2 stack を destroy しても残ります。

## アーキテクチャ

```
trn2.48xlarge (Spot or CB)
├─ NVMe RAID0  /mnt/local   ← 6.6 TB ephemeral, 高速 I/O
│                              ├─ /mnt/local/neuron-compile-cache (NEFF hot copy)
│                              └─ (compile workdir 等の一時ファイル)
└─ EFS NFS4    /mnt/efs     ← 永続、 elastic throughput
                               └─ /mnt/efs/neuron-workspace/
                                  ├─ neuron-compile-cache/  (10 min ごとに NVMe からバックアップ)
                                  ├─ models/                ← NEW
                                  │  ├─ hf-cache/           (HF snapshots, ~110 GB)
                                  │  ├─ whisper-large-v3-neuron/   (13 GB)
                                  │  ├─ qwen-image-edit-compiled/  (80 GB)
                                  │  └─ qwen3-vl-compiled/         (10 GB)
                                  └─ voice-image-edit/      ← NEW
                                     ├─ whisper-server/
                                     ├─ qwen3-vl-server/
                                     └─ qwen-image-edit-server/
```

正準パス → EFS への symlink layer で透明化:

```
/models/                                  -> /mnt/efs/neuron-workspace/models
/opt/voice-image-edit                     -> /mnt/efs/neuron-workspace/voice-image-edit
/mnt/local/compiled_models                -> /mnt/efs/neuron-workspace/models/qwen-image-edit-compiled
/opt/dlami/nvme/qwen_image_edit_hf_cache_dir -> /mnt/efs/neuron-workspace/models/hf-cache
```

`models/whisper/tasks/whisper-precompile.json` の `MODEL_DIR=/models/whisper-large-v3-neuron` などは
そのまま使える。 setup-efs-paths.sh が EFS に reroute する。

## 起動シーケンス (boot 時)

```
1. cloud-init / EC2 user-data
   └─ setup/single-node/scripts/setup-persistence.sh  (既存)
       ├─ /mnt/local を NVMe RAID0 で format + mount
       ├─ /mnt/efs を NFS4 で mount (/etc/fstab)
       ├─ NEFF cache を EFS から NVMe へ rsync (cache hit 復元)
       └─ neff-backup.timer enable (NVMe -> EFS 10 min 毎)

2. samples/voice-image-edit/scripts/setup-efs-paths.sh  (NEW、 idempotent)
   ├─ /mnt/efs/neuron-workspace/{models,voice-image-edit} を mkdir
   ├─ 既存 /mnt/local/compiled_models や /models/whisper-large-v3-neuron に
   │   data があれば EFS へ rsync (初回 migration)
   └─ canonical paths を symlink で EFS に向ける

3. systemd unit (whisper.service / qwen3-vl.service / qwen-image-edit.service)
   └─ ExecStartPre= で setup-efs-paths.sh を 1 度だけ走らせる
       (symlink が既にあれば一瞬で抜ける)
```

## Recovery シーケンス (CB / Spot terminate 後)

CodeBuild Capacity Block が消えて新しい trn2 が立ったケース:

```
1. CDK で base stack (storeai-validation-use2 等) 再 deploy
   └─ EFS は RETAIN なので同じ fs-... が再 attach される
   └─ EC2 は新しいインスタンス (compile artifact なし、 NEFF cache なし)

2. EC2 cloud-init で setup-persistence.sh が走る
   └─ /mnt/efs を mount すると model 群はそこに居る (compile 済 + HF 済)
   └─ NEFF cache を NVMe にコピーするので compile cache hit する

3. samples/voice-image-edit/scripts/deploy-all.sh を 1 撃で再実行
   └─ 各 prepare task は cached artifact を見て即 SKIP
   └─ 各 server task は systemd unit を install/restart
   └─ ApiStack の TRAINIUM_*_URL は systemd drop-in で復元
   └─ 起動 5-10 分でサービング再開
```

`compile.sh` 自体は idempotent ではないが、 task JSON の `10-skip-if-cached`
ステップが `transformer_v3_cfg/`, `vae_encoder/`, `vae_decoder/`,
`language_model_v3/`, `vision_encoder_v3/` を確認してそれら全部が EFS に
あれば `compile.sh` を起動しない。

## 一撃デプロイ

```bash
AWS_PROFILE=claude-code bash samples/voice-image-edit/scripts/deploy-all.sh \
  --base-stack-name storeai-validation-use2 \
  --region us-east-2
```

実行する steps (sequential, 各 step は idempotent):

| # | step | 内容 | 通常時 | recover 時 |
|---|---|---|---|---|
| 1 | precheck | base stack output / EFS mount / NeuronCore を確認 | <1s | <1s |
| 2 | setup-efs-paths | symlink layer (`/models`, `/opt/voice-image-edit` 等) を EFS へ向ける | 1s | 1s |
| 3 | whisper-precompile | encoder/decoder/proj.pt を EFS に compile | ~30 min | skip |
| 4 | qwen3-vl-prepare | weights + warmup を EFS に置く | ~20 min | skip |
| 5 | qwen-image-edit-prepare | V3 CFG 5 component を EFS に compile | ~60 min | skip |
| 6 | whisper-server | systemd unit install + start (port 8765) | ~5 min | ~2 min |
| 7 | qwen3-vl-server | systemd unit install + start (port 8090) | ~5 min | ~2 min |
| 8 | qwen-image-edit-server | systemd unit install + start (port 8081) | ~10 min | ~5 min |
| 9 | voice-image-edit deploy | ApiStack/FrontendStack/StreamStack に TRAINIUM_*_URL=http://127.0.0.1:{8765,8090,8081}/... を inject | ~5 min | ~5 min |

合計: 通常時 ~120 min / recover 時 ~15 min。

## キャッシュの再利用ルール

- HF download は EFS にあれば skip。ない場合は EFS に直接 download。
- Neuron compile は NEFF cache 経由で大幅短縮。 `compile.sh` は出力 dir
  (`/mnt/local/compiled_models -> EFS`) に target が完全に揃っていれば
  task JSON 側で skip される。
- voice-image-edit-{api,frontend,stream} の tarball は毎回 build → S3 stage
  → SSM 経由の現状を維持 (build artifact は git tracked source の derivative
  なので再生成のほうが正しい)。

## 注意: Sensitive な値

- HMAC OriginVerifySecret は Secrets Manager 上に残す。 EFS には書かない。
- HF Token は EC2 の `~ubuntu/.cache/huggingface/token` のままで、 EFS には
  コピーしない (instance を逃がす運用とずれるので別運用)。

## 移行手順 (現在の us-east-2 EC2 から EFS へ)

```bash
# 1) EFS dirs を準備 + symlink を貼る
ssm send-command -i i-0b540e59a1f4f4234 -f tasks/setup-efs-paths.json

# 2) 既存 NVMe / root fs 上の artifact を EFS へ rsync (初回 migration)
ssm send-command -i i-0b540e59a1f4f4234 -f tasks/migrate-to-efs.json
```

`tasks/setup-efs-paths.json` と `tasks/migrate-to-efs.json` は
`samples/voice-image-edit/scripts/tasks/` に置く。
