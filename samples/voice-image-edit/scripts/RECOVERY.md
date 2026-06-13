# voice-image-edit one-shot deploy + Spot terminate recovery

このドキュメントは `deploy-all.sh` を「初回」「キャッシュ再利用」「CodeBuild Capacity Block / EC2 Spot terminate 後 recovery」の 3 シナリオで使う手順を定義する。

## 共通: 必須環境

```bash
export AWS_PROFILE=claude-code   # 厳守
cd samples/voice-image-edit/scripts
```

## アーキテクチャ要約

3 モデルサーバ + アプリスタックの構成:

```
EC2 (trn2.48xlarge)
├── /models                       -> EFS/neuron-workspace/models
│   ├── whisper-large-v3-neuron/      (~1 GB, encoder/decoder/proj.pt)
│   ├── Qwen3-VL-8B-Instruct/         (~16 GB, vLLM warmup artifact)
│   ├── hf-cache/                     (~110 GB, HF download)
│   └── qwen-image-edit-compiled/     (alias for /mnt/local/compiled_models)
├── /opt/voice-image-edit         -> EFS/neuron-workspace/voice-image-edit
│   ├── whisper-server/
│   ├── qwen3-vl-server/
│   ├── qwen-image-edit-server/
│   └── (api, stream, frontend, edit) — application backends
├── /mnt/local/compiled_models    -> EFS/neuron-workspace/models/qwen-image-edit-compiled  (~80 GB CFG artifacts)
└── /opt/dlami/nvme/qwen_image_edit_hf_cache_dir -> EFS/neuron-workspace/models/hf-cache
```

すべての永続化対象が EFS (`fs-029fe5d964cd09c7c`) 上に置かれているので、 EC2 が CB Spot terminate されて新しい instance に置き換わっても、 同じ EFS を mount して symlink 層を再構築すれば、 NEFF cache hit でゼロから再 compile せずに数分でサーバを復活できる。

## サーバ port

| service                 | port | path                                | venv |
|-------------------------|------|-------------------------------------|---------------------------------------------------|
| whisper-server          | 8765 | /transcribe, /health                | /opt/aws_neuronx_venv_pytorch_2_9_nxd_inference   |
| qwen3-vl                | 8090 | /v1/chat/completions, /health       | /opt/aws_neuronx_venv_pytorch_inference_vllm_0_16 |
| qwen-image-edit         | 8081 | /infer (multipart), /health         | /opt/aws_neuronx_venv_pytorch_2_9_nxd_inference   |
| voice-image-edit-stream | 8800 | /stream/* (SSE)                     | (own venv)                                        |
| voice-image-edit-api    | 8801 | /api/edit/*                         | (own venv)                                        |
| voice-image-edit-frontend | 3000 | / (Next.js)                       | (Node)                                            |

## シナリオ A: 初回デプロイ (EC2 が空)

EFS 永続化未設定。 NVMe / root fs に直接 compile して EFS にコピーするのは時間が無駄なので、 最初から EFS 直接出力。

```bash
bash deploy-all.sh \
  --base-stack-name <STACK> \
  --region us-east-2
```

実行内容: precheck → setup-efs-paths (空 EFS に symlink) → 3 prepare (compile + HF download, ~1 h) → 3 server (systemd 起動, ~10 min) → app stack (CDK).

## シナリオ B: キャッシュ再利用 (同一 EC2 で再実行)

deploy-all.sh は冪等。 各 task は `state-file` で「completed」を記録しているので、 実質 noop で抜ける。 サーバが既に起動していれば health check のみ走る。

```bash
bash deploy-all.sh \
  --base-stack-name <STACK> \
  --region us-east-2
```

## シナリオ C: CB Spot terminate → 新 EC2 で recover

CodeBuild の Capacity Block が exhaust すると EC2 instance は terminate される。 base stack を再 deploy すると新しい EC2 が立ち上がり、 同じ EFS が mount される (CDK efs-persistence-stack に ClientMount 権限あり)。

このとき deploy-all.sh は以下の差分を回す:

1. setup-efs-paths.json — `/models` `/opt/voice-image-edit` `/mnt/local/compiled_models` `/opt/dlami/nvme/qwen_image_edit_hf_cache_dir` がすべて空 directory として作られている → EFS に向いた symlink に張り替えるだけ (rsync 不要)
2. 3 prepare — compile artifact が EFS にあるので NEFF cache hit、 数分で抜ける
3. 3 server — systemd 起動 + cold model load (~10 min for QIE)
4. voice-image-edit-app — base stack の VPC/SG が変わっていない限り CDK no change

```bash
bash deploy-all.sh \
  --base-stack-name <STACK> \
  --region us-east-2 \
  --recover
```

`--recover` は `migrate-to-efs` step を skip する (default 動作)。 既に EFS 上にあるデータを root fs に rsync する必要は無い。

### CB recovery の boot 時間目安

| 工程                                      | 時間   |
|-------------------------------------------|--------|
| base stack redeploy (EC2 + EFS mount)     | ~5 min |
| setup-efs-paths (symlink swap)            | <1 min |
| whisper-precompile (cache hit)            | ~2 min |
| qwen3-vl-prepare (cache hit)              | ~3 min |
| qwen-image-edit-prepare (cache hit)       | ~5 min |
| 3 server systemd start + cold load        | ~10 min (QIE が支配的) |
| voice-image-edit-app (CDK no-change)      | ~3 min |
| **合計**                                   | **~30 min** |

vs cold start (EFS 無し、 全部 recompile): ~5 hours

## シナリオ D: 既存 EC2 の root fs / NVMe から EFS へ初回移行

deploy-all.sh を NVMe に compile artifact が残っている既存 EC2 で初めて回す場合:

```bash
bash deploy-all.sh \
  --base-stack-name <STACK> \
  --region us-east-2 \
  --migrate
```

`--migrate` を付けると `migrate-to-efs` step が有効化され、 setup-efs-paths の前に rsync ~195GB (compile + HF cache + サーバ source) が走る。 ~30-40 min の I/O。 ただしサービス起動中でも実行可能 (rsync の対象は read-only な artifact のみ)。

## subset 実行

debug 用に特定 step のみ実行可能:

```bash
# server だけ再起動
bash deploy-all.sh --base-stack-name <STACK> \
  --only whisper-server,qwen3-vl-server,qwen-image-edit-server

# app stack だけ再 deploy
bash deploy-all.sh --base-stack-name <STACK> \
  --only voice-image-edit-app
```

## 動作確認

```bash
# instance の SSM 経由 health check
aws ssm send-command --region us-east-2 \
  --instance-ids <INSTANCE_ID> \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["for p in 8765 8090 8081 8800 8801; do echo -n \"$p: \"; curl -s -o /dev/null -w \"%{http_code}\\n\" http://127.0.0.1:$p/health; done"]'

# CloudFront 経由 (要 Cognito cookie)
curl -sS https://<cloudfront-domain>/api/edit/health --cookie 'cf_session=...'
curl -sN https://<cloudfront-domain>/stream/health --cookie 'cf_session=...'
```

## 設計の要点

1. **冪等性**: 各 task に state-file。 既に completed なら noop で次へ。
2. **キャッシュ層**:
   - HF download は `/models/hf-cache/hub/` (HF_HOME=`/models/hf-cache`)。 redownload 不要。
   - NEFF cache は `/var/tmp/neuron-compile-cache/` (root fs だが OS 管理) と `/mnt/local/compiled_models/` (EFS via symlink)。 cache hit で数分。
3. **永続化境界**: 永続化したい "compute artifact" のみ EFS。 venv (/opt/aws_neuronx_venv_*) や OS 設定 (/etc/systemd/...) は AMI 由来なので新 EC2 でも同じ。
4. **サーバ source も EFS**: CB recovery で source tarball を再 download する必要が無いので、 stage S3 bucket の TTL 切れに依存しない。
