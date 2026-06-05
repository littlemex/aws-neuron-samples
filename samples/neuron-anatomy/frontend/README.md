# @aws-neuron-samples/neuron-anatomy (frontend)

Trainium のチップを「物理構造そのまま」描く React コンポーネント群。
neuron-anatomy backend (`/neuron/topology`, `/neuron/stream`) を SSE 購読して、
NeuronCore-v3 のエンジン (Tensor / Vector / Scalar / GPSIMD) や HBM スタック、
NeuronLink Torus を解剖図として描画する。

## 利用例 (voice-image-edit に埋め込む場合)

```ts
import { NeuronDrawer } from '@aws-neuron-samples/neuron-anatomy';

export default function EditPage() {
  return (
    <main className="flex h-screen flex-col">
      <PipelineRegion />
      <NeuronDrawer base="/neuron" defaultOpen />
    </main>
  );
}
```

`base` は CloudFront/ALB を経由する場合の prefix。standalone backend
(`uvicorn main:app --port 8810`) を直接叩くなら `http://localhost:8810/neuron`。

## 描画と telemetry の対応

| 描画要素 | 駆動データ | 種別 |
| --- | --- | --- |
| NeuronCore セル fill | `cores[].utilisation` | live |
| v3d.0 / v3d.1 サブバー | `cores[].v3d_sub` (LNC=2 のみ) | live |
| TensorEngine / VectorEngine / ScalarEngine / GPSIMDEngine | なし | static silhouette |
| SRAM bar | `cores[].memory_used_bytes` / engine_specs.sram_per_neuroncore_bytes | derived |
| HBM stack fill | `chips[].hbm_used_bytes` / `chips[].hbm_total_bytes` | derived |
| Chip outline glow | `chips[].avg_utilisation` | derived |
| ECC バッジ | `chips[].ecc_corrected/uncorrected` | live |
| NeuronLink エッジ | `topology.edges` | static |

## インスタンス非依存性

- chip 数: `topology.neuron_device_count`
- chip あたり logical core 数: `topology.chips[].nc_count`
- HBM 容量: `topology.chips[].memory_size`
- LNC mode: `topology.logical_neuroncore_config` (1 or 2)
- 隣接トポロジ: `topology.edges` (= `neuron-ls -j connected_to[]` の双方向辺)

frontend には trn2.48xlarge / 16 chip / 64 core を一切ハードコードしていない。
trn2.3xlarge (1 chip) でも UltraServer (64 chip) でも同じコードで表示できる。
