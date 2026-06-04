# Trainium2 ハードウェアノート (描画用リファレンス)

`samples/neuron-anatomy/frontend` の図はすべて以下の物理構造をベースに描いている。
描画値が間違ったらまずこのドキュメントを参照する。出典は AWS Neuron Documentation。

## Trainium2 chip

- 物理 NeuronCore-v3: **1 chip = 8 個**
- HBM: **96 GiB / chip**, バンド幅 2.9 TB/s, スタック数 4
- on-chip SRAM (SBUF): **224 MiB / chip** (= 28 MiB × 8 NeuronCore)
- DMA: 3.5 TB/s (in-line compress/decompress)
- Collective Communication Cores: 16 / chip (描画では NeuronLink fabric の一部
  として扱い、独立ブロックは描かない)

## NeuronCore-v3 内部 (1 個ぶん)

- TensorEngine: 158 cFP8 TFLOPS / 79 BF16 TFLOPS / 316 sparse TFLOPS (4:16, 4:12,
  4:8, 2:8, 2:4, 1:4, 1:2)
- VectorEngine: 1 TFLOPS FP32
- ScalarEngine: 1.2 TFLOPS FP32
- GPSIMDEngine: 8x 512-bit programmable vector processors
- on-core SRAM: 28 MiB (software-managed)

`neuron-monitor` は per-engine util を出さないので、図ではこれらをすべて
**静的シルエット**として描く。色塗りは `NeuronCore` 単位の `neuroncore_utilization`
だけが driver。

## LNC mode

- LNC=1: 1 logical core = 1 physical NeuronCore-v3
- LNC=2 (Trn2 default): 1 logical core = 2 physical NC-v3 を fuse (NC_V3d)
- `neuron-monitor` の `v3d.nc_v3.{0,1}.neuroncore_utilization` で 2 物理コアの
  内訳が取れる。`logical_neuroncore_config` を見て表示の有無を切り替える。

## トポロジ

- trn2.48xlarge / trn2u.48xlarge: 16 chips を NeuronLink-v3 で **4x4 2D Torus**
  に接続。1 chip あたり intra-instance 1024 GB/s。
- Trn2 UltraServer: 4 ノード x 16 chip = 64 chip。各ノード内は 4x4 Torus、
  ノード間は **同じ chip 座標同士のリング** で 256 GB/s/chip。
- `neuron-ls -j` の `connected_to[]` がこの adjacency を返すので、frontend は
  ここから layout を組む (ハードコードしない)。

## インスタンスごとの差分

| SKU | chips | NeuronCore (LNC=1) | NeuronCore (LNC=2) | HBM 合計 | トポロジ |
| --- | --- | --- | --- | --- | --- |
| trn2.3xlarge | 1 | 8 | 4 | 96 GiB | 単一 chip / 隣接なし |
| trn2.48xlarge | 16 | 128 | 64 | 1,536 GiB | 4x4 2D Torus |
| trn2u.48xlarge | 16 | 128 | 64 | 1,536 GiB | 4x4 2D Torus + UltraServer port |
| Trn2 UltraServer | 64 | 512 | 256 | 6,144 GiB | 4 nodes x 4x4 Torus + ring |

frontend の `lib/layout.ts` は chip 数 1 / 16 / 64 / その他で grid 配置を決め、
`engine_specs` (静的ラベル) は backend が `chip_engine_specs` で送る値を使う。

## 取れない telemetry

これらは現状 `neuron-monitor` には公開されていないので、図上は静的扱い:
- per-engine (Tensor / Vector / Scalar / GPSIMD) utilisation
- HBM 帯域 (read / write GB/s)
- NeuronLink 帯域 (link 単位)

将来 telemetry が公開されたら `monitor.py` で取り込み、`NeuronCoreSample` /
`ChipSample` / `TopologyEdge` にフィールド追加すれば frontend も連動する。
