# neuron-anatomy: 他サンプルへの組み込み手順

## 1. backend を立てる (1 度だけ)

EC2 に systemd unit を入れて常駐させる。voice-image-edit と同じインスタンスを
使い回す前提なので、複数サンプルが同時に動いても neuron-monitor は 1 本だけ。

```bash
# tarball を SSM 経由で /opt/neuron-anatomy/ に展開してから:
sudo cp /opt/neuron-anatomy/systemd/neuron-anatomy.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now neuron-anatomy
sudo systemctl status neuron-anatomy
```

## 2. ALB ルールを 1 本足す (1 度だけ)

`infra/lib/neuron-anatomy-stack.ts` を CDK deploy。priority 250 / `/neuron/*` /
EC2:8810 を生やす。voice-image-edit の {api,stream,frontend}-stack と完全に
独立した stack として運用できる。

## 3. frontend で `NeuronDrawer` を mount する

### 3a. file: 依存で他サンプルから引く (推奨)

```jsonc
// 他サンプルの frontend/package.json
{
  "dependencies": {
    "@aws-neuron-samples/neuron-anatomy": "file:../../neuron-anatomy/frontend"
  }
}
```

```tsx
import { NeuronDrawer } from '@aws-neuron-samples/neuron-anatomy';

export default function YourPage() {
  return (
    <main className="flex h-screen flex-col">
      <YourMainContent />
      <NeuronDrawer base="/neuron" defaultOpen />
    </main>
  );
}
```

### 3b. backend を「自前 FastAPI に同居」させたい場合

`/neuron/*` を別 ALB ルールにせず、既存サービスにルータをマウントする選択も
できる。ただし neuron-monitor subprocess がサンプル数だけ重複起動する
リスクがあるので、利用は単一 backend 構成のサンプルに限る。

```python
from fastapi import FastAPI
from neuron_anatomy import router as neuron_anatomy_router
from neuron_anatomy.monitor import monitor_service
from neuron_anatomy.topology import topology_cache

app = FastAPI()
app.include_router(neuron_anatomy_router)

@app.on_event('startup')
async def _bootstrap():
    await topology_cache.get()
    await monitor_service.start()
```

## 4. 認証 (CloudFront / Cognito)

`/neuron/*` も既存の CloudFront Function (cf_session HMAC) で保護される。
ALB rule に X-Origin-Verify ヘッダ条件が付くので origin verify secret も
他のルールと同じ Secrets Manager の値を使う。frontend からのリクエストは
すべて same-origin (`/neuron/...`) になるので、CORS 追加は不要。

## 5. インスタンスタイプ非依存

frontend は `topology.neuron_device_count` / `chips[].nc_count` /
`topology.logical_neuroncore_config` を見て描画レイアウトを決める。
trn2.3xlarge (1 chip)・trn2.48xlarge (16 chip)・UltraServer (64 chip) で
同じ component が動く。`engine_specs` だけは backend 側に静的に持たせて
いるので、世代を切り替えるときは backend だけ更新すればよい。
