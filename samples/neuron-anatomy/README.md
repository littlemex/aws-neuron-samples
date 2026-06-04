# neuron-anatomy

Trainium のハードウェア構造を「そのまま」描き、neuron-monitor と neuron-ls
が公開する live telemetry を物理レイアウトの上に重ねる、可視化サンプル。

このサンプルは **任意の AWS Neuron アプリ** に埋め込んで使えるよう、
意図的に voice-image-edit から切り離して作られている。voice-image-edit は
このコンポーネントの最初の利用者にすぎない。

## 構成

```
neuron-anatomy/
├── backend/                           FastAPI: neuron-monitor 購読 + SSE
│   ├── neuron_anatomy/                pip-installable package
│   ├── main.py                        standalone uvicorn entrypoint
│   ├── pyproject.toml
│   └── tests/
├── frontend/                          @aws-neuron-samples/neuron-anatomy
│   ├── src/
│   │   ├── components/                NeuronDrawer / ChipGrid / ChipDiagram ...
│   │   ├── hooks/                     useNeuronStream / useNeuronTopology
│   │   ├── lib/                       derive / layout
│   │   ├── types.ts                   backend schemas と 1:1
│   │   └── index.ts                   public API
│   ├── package.json                   peerDependencies: react / react-dom
│   └── README.md
├── infra/                             CDK スタック (NeuronAnatomyStack)
│   └── lib/neuron-anatomy-stack.ts    ALB rule /neuron/* priority 250
├── systemd/
│   └── neuron-anatomy.service         port 8810 で uvicorn を起動
├── examples/
│   └── standalone-page/               1 ページだけのデモ用 Next.js page
├── docs/
│   ├── ARCHITECTURE.md
│   ├── EMBEDDING.md                   他サンプルへの組み込み手順
│   └── HARDWARE_NOTES.md              Trainium2 物理構造リファレンス
└── README.md
```

## 設計原則

1. **インスタンスタイプを一切ハードコードしない**。chip 数・コア数・HBM 容量
   は全て `neuron-ls -j` と `neuron-monitor` の `neuron_hardware_info` から
   動的に取得する。trn2.3xlarge (1 chip) も trn2.48xlarge (16 chip) も
   UltraServer (64 chip) も同じコードで表示できる。
2. **テレメトリの有無で「色塗り」と「シルエット」を分ける**。NeuronCore 単位
   の utilisation は live で色変化、エンジン (Tensor/Vector/Scalar/GPSIMD)
   は telemetry が無いので静的シルエット表示にとどめる。telemetry が
   将来追加されたら静的扱いを差し替える。
3. **既存サービスに依存しない**。voice-image-edit-stream とも api/edit とも
   独立したスタンドアロン service として動く。CloudFront / ALB の認証ゲート
   (cf_session HMAC + X-Origin-Verify) はそのまま継承し、rule 1 本だけ
   追加する。
4. **pub/sub で多人数視聴に耐える**。neuron-monitor は OS 全体で 1 本だけ。
   各 SSE クライアントは独立した queue を持ち、遅いクライアントは
   latest-wins で古い値を捨てて backend に backpressure を伝えない。

## 動作確認 (実機なし)

`NEURON_ANATOMY_FAKE_MONITOR=1 NEURON_ANATOMY_FAKE_TOPOLOGY=1` を立てて
backend を起動すれば、trn2.48xlarge 風の 16 chip 4x4 Torus を
波形シミュレーションで返してくれる。ブラウザに何も繋がっていない状態で
Drawer が機能することを確認できる。

```bash
cd backend
pip install -e '.[dev]'
NEURON_ANATOMY_FAKE_MONITOR=1 NEURON_ANATOMY_FAKE_TOPOLOGY=1 \
  uvicorn main:app --port 8810
```

## 動作確認 (実機: SSM 越し)

```bash
# 既存 voice-image-edit サンプルの SSM start-session でログイン後
cd /opt/neuron-anatomy/backend
sudo systemctl start neuron-anatomy
sudo journalctl -u neuron-anatomy -n 50

# CloudFront 越しの確認
curl -H 'cookie: cf_session=...' https://<cloudfront-dist>/neuron/health
curl -N -H 'cookie: cf_session=...' https://<cloudfront-dist>/neuron/stream
```

## Deploy

`scripts/deploy.sh` is the one-shot deploy helper. Modelled after
`samples/voice-image-edit/scripts/deploy-all.sh`, it resolves every CFN
output it needs from `<base>` and `<base>-alb`, stages the backend
tarball through S3, runs a 6-task SSM runner to install the
`neuron-anatomy.service` systemd unit, then `cdk deploy`s
`NeuronAnatomyStack` to attach `/neuron/*` (priority 250) to the
existing internal ALB.

```bash
AWS_PROFILE=claude-code bash scripts/deploy.sh \
  --base-stack-name storeai-validation-use2 \
  --region us-east-2
```

Flags:

- `--alb-stack-name NAME` — override the default `<base>-alb`.
- `--only backend|infra|integrate` / `--skip ...` — target a subset of steps.
- `--integrate-voice-image-edit` — also patch
  `samples/voice-image-edit/app/frontend/src/app/edit/page.tsx` to
  mount `<NeuronDrawer />` and add the `file:` dependency to its
  `package.json`. After this you still need to ship the patched
  frontend with `voice-image-edit/scripts/deploy-all.sh --only voice-image-edit-app`.
- `--dry-run` — print every step without touching SSM / CDK.

A non-zero exit emits a final-line marker so wrappers that pipe
through `tee` can still detect failure:

```
[anatomy][NG] failed at step '<step>' (exit=<n>)
```

For embedding the React component into other samples see
[docs/EMBEDDING.md](./docs/EMBEDDING.md).
