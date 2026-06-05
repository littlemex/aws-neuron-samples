# neuron-anatomy アーキテクチャ

## データフロー

```
+-----------------+      stdout JSONL (1s)        +----------------------+
| neuron-monitor  | ----------------------------> |  monitor.py          |
| (singleton OS)  |                                |  - asyncio reader    |
+-----------------+                                |  - normalize -> Snap |
                                                   |  - pub/sub queues    |
                                                   +----------+-----------+
                                                              |
                                                              v
+-----------------+      one-shot at startup       +----------------------+
| neuron-ls -j    | ----------------------------> |  topology.py         |
+-----------------+                                |  - parse devices     |
                                                   |  - dedup edges       |
                                                   |  - cache             |
                                                   +----------+-----------+
                                                              |
                                                              v
                                                   +----------------------+
                                                   |  router.py (FastAPI) |
                                                   |  - /neuron/health    |
                                                   |  - /neuron/topology  |
                                                   |  - /neuron/snapshot  |
                                                   |  - /neuron/stream    |
                                                   +----------+-----------+
                                                              |
                              ALB /neuron/* (priority 250)    | text/event-stream
                                                              v
+-----------------+      cf_session + X-Origin-     +----------------------+
| Browser (React) | <-- Verify HMAC ---------------+ | useNeuronStream      |
| NeuronDrawer    |                                  | useNeuronTopology    |
+-----------------+                                  +----------------------+
```

## Backend の責務分離

- `monitor.py`: neuron-monitor stdout を読んで生 JSON line を `Snapshot` に
  正規化、各 SSE 購読者に push。`Snapshot` は frontend が即座にレンダーできる
  形 (chips/cores/runtimes に集約済) になっており、frontend はもはや
  neuron-monitor の生スキーマを知らなくてよい。
- `topology.py`: `neuron-ls -j` の `connected_to[]` をそのまま辺集合に展開。
  `neuron-ls` 出力の表記ゆれ (top-level array vs `neuron_devices` キー) を
  ここで吸収。chip 数や `nc_count` のハードコードは無い。
- `router.py`: FastAPI APIRouter のみ。SSE keep-alive (10s heartbeat) と
  `Cache-Control: no-cache, X-Accel-Buffering: no` を付ける。voice-image-edit
  の `/stream/pipeline` と完全に同じ流儀。
- `main.py`: standalone uvicorn entrypoint。`@asynccontextmanager` で
  topology 初期化 → monitor 起動 → 終了時に monitor stop の lifespan を組む。

## Frontend の責務分離

- `useNeuronTopology`: 起動時 1 度だけ `/neuron/topology` を fetch し、結果を
  state に保持。エラー時もコンポーネントは壊れない (フォールバック描画)。
- `useNeuronStream`: `EventSource` で `/neuron/stream` を購読。`enabled` で
  on/off できるので、Drawer が閉じているときは購読を停止する。
- `lib/layout.ts`: chip 数からグリッド配置 (1, 16, 64, それ以外) を決定。
  `connected_to[]` を chip 配置座標に変換し、edge を 2D 線分にする。
- `lib/derive.ts`: `chip / core` 単位の % や fill 比率の計算をまとめる。
  この層を独立させているのは、recharts 等でグラフ表示したいユーザが
  描画コンポーネントを使わずに値だけ取り出せるようにするため。
- `components/`:
  - `NeuronCoreCell.tsx`: 1 NeuronCore の解剖図 (Tensor/Vector/Scalar/GPSIMD
    シルエット + SRAM bar + utilisation 色塗り)。
  - `ChipDiagram.tsx`: 1 chip (HBM stacks + NeuronCore グリッド)。
  - `ChipGrid.tsx`: 全体図 (NeuronLink エッジを SVG 重ね、各 chip を
    `ChipDiagram compact` で並べる)。
  - `NeuronDrawer.tsx`: voice-image-edit に埋め込む top-level component。
    折り畳み時はヘッダ 1 行、展開時は左 (全体図) + 右 (拡大解剖図)。

## 並行性

- backend は asyncio 単一スレッド + neuron-monitor subprocess。
- pub/sub の queue は `maxsize=4` で latest-wins (古い値を捨てる)。
  これにより 1 人遅い視聴者が居ても backend が詰まらない。
- voice-image-edit-stream の SSE と HTTP path が分かれているので、
  ロック共有も無く完全に独立して動く。

## 拡張ポイント

- per-engine util telemetry が将来追加されたら、`monitor.py` の `_extract_cores`
  にエンジン値を追加し、`NeuronCoreCellProps` に渡す。`NeuronCoreCell.tsx`
  内のシルエットを fill 駆動に切り替える。
- HBM 帯域 / NeuronLink 帯域 telemetry が追加されたら同様に `chips[]` /
  `edges[]` にフィールドを足す。frontend は `placeEdges` の戻り値を
  色付け / 太さ駆動に変える。
- inferentia / trn1 など別世代では `chip_engine_specs` だけ backend で
  分岐させ、frontend には触らない。
