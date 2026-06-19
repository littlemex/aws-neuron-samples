# Qwen-Image-Edit クラッシュループ — 根本原因と恒久対策

`RuntimeError: Expected weight tensors for 8 ranks. Received 32`
（2026-06 本番インシデント / trn2.48xlarge / voice-image-edit デモ）

このドキュメントは、`NxDModel.to_neuron()` の深部でしか観測できなかった上記エラーの
根本原因を実機検証付きで確定し、その場しのぎ（`rm -rf` でのキャッシュ全削除）に頼らない
恒久対策を、実装と検証手順とともに記録する。

---

## 1. 結論 (Root Cause)

### 一次根本原因（実証済み）

**Neuron 永続コンパイルキャッシュが、過去の `world_size=8` 用 NEFF（SPMD グラフ）を
`world_size=32` のコンパイル要求に対してヒットさせ、8-rank グラフを返した。**

`libneuronxla` のコンパイルキャッシュは `sha256(HLO + compiler_flags)` をキーにする
（`libneuronxla/neuron_cc_cache.py`）。CFG-parallel transformer の HLO は world_size の
違いを十分に反映しないため、`v3_cfg`（`--world_size 8`）で蓄積されたキャッシュエントリが
`v3_tp16`（`--world_size 32`）の要求にヒットし、**約3分**で 8-rank の `nxd_model.pt` を
返した（正規コンパイルは 90-120 分）。一方 `config.json`（`world_size=32`）と
weight shards（16 本）は新規生成されたため、グラフだけが 8-rank という三者不整合が生じ、
`serve.py` の `set_weights(32)` → `to_neuron()` がランク不一致で例外を投げた。

**決定的証拠（一変量実験）**: キャッシュ未削除での再コンパイル → 約3分・8-rank・失敗。
キャッシュ削除 + クリーン再コンパイル → 正規時間・32-rank・正常起動。

### 寄与・悪化因子（確認済み）

| ID | 因子 | 影響 |
|---|---|---|
| CF-1 | `/mnt/local/compiled_models_tp16` を EFS への symlink にした | EFS root-squash で `mkdir -p` が EPERM → compile 中断・partial state |
| CF-2 | `run-tasks.sh` の state file がコマンド文字列 fingerprint で `40-compile` を "Already completed" にしてスキップ | アーティファクト削除後も再コンパイルが発火せず、復旧を反復的に阻害 |
| CF-3 | コンパイル出力が root:root 0600、systemd unit は `User=ubuntu` | weight safetensors が EACCES（FileNotFoundError）— ランク不一致とは別経路のクラッシュ |
| CF-4 | `setup-efs-paths` の EFS link 先が `compiled_models`（サフィックス無）で実パス `compiled_models_tp16` と不一致 | EFS 永続化が機能せず、instance 交換のたびに全再コンパイル |
| CF-5 | `ModelBuilder(model=model)` に `world_size` 引数なし（NxDParallelState から暗黙継承） | 今回は未発火のラテントリスク |

---

## 2. なぜ何度もハマったか（非決定性の正体）

オペレーターが「再コンパイル → 再起動」を試みるたびに別のトラップに入った:

1. **state file スキップ (CF-2)** — コマンド文字列が不変なので `40-compile` が握り潰され、
   アーティファクトを消しても再コンパイルが走らない。
2. **EFS symlink の mkdir EPERM (CF-1)** — symlink を実 dir に直すまで compile が中断。
3. **stale cache hit (一次原因)** — ようやく compile が走っても約3分で 8-rank が返り、
   「また失敗した」ように見える。
4. **root-0600 (CF-3)** — ランク問題とは無関係な EACCES クラッシュが重なる。

同一コマンドが「3分・失敗」と「120分・成功」の二値を返す（キャッシュ削除の有無で分岐）ため、
原因が複数あるように見え、非決定的に映った。

---

## 3. 高級対策（実装済み）

実機検証で設計を補正済み。特に「`nxd_model.pt` から rank を読んで照合」案は
**CPU では `torch.jit.load` が `__torch__.torch.classes.neuron.SPMDModel` 未登録で失敗する**
ため不採用とし、**コンパイル時に書く `.compile_stamp` を真実の源とする**方式に変更した。

### P0-A: コンパイルキャッシュを VERSION_MODE でスコープ分離 — `compile.sh`

不変条件: ある並列レイアウト用のグラフが、別レイアウトの要求に再利用され得ない。

```sh
COMPILER_WORKDIR="${COMPILER_WORKDIR%/}/${VERSION_MODE}"
export NEURON_COMPILE_CACHE_URL="${NEURON_COMPILE_CACHE_URL:-file:///mnt/local/neuron-compile-cache/${VERSION_MODE}}"
export VERSION_MODE
```

`v3_cfg` は `.../neuron-compile-cache/v3_cfg`、`v3_tp16` は `.../v3_tp16` を使うため、
cross-layout の stale hit が構造的に起きない。同一レイアウトの再コンパイルは正しくヒットする
（高速かつ正しい）。`rm -rf` での全削除に依存しない恒久解。

### P0-B: serve 前整合性ゲート — `neuron_qwen_image_edit/verify_artifacts.py` + `serve.py`

`.compile_stamp`（後述）が存在し、`stamp.world_size == config.world_size` かつ
`stamp.tp_degree == config.tp_degree` かつ weight shard 数 == `tp_degree` のときだけ serve する。
不整合は `to_neuron()` 深部ではなく起動時に明確なメッセージで停止する。
旧アーティファクト（stamp 無し）は警告のみで継続（`QIE_REQUIRE_STAMP=1` で厳格化）。

> 意図的に避けた検査: `nxd_model.pt` と weights の mtime 比較。compiler はグラフを
> weights より**先**に書くため、正常時もグラフが古く、mtime 比較は偽陽性を出す
> （インシデント対応中に実際に誤検知を起こした）。stamp は順序非依存の正しい信号。

### P0-C: 完了スタンプ — `compile_transformer_v3_cfg.py`

全アーティファクト（グラフ・shards・config・rope）を書き終えた**最後に**
`.compile_stamp` を `os.replace` でアトミックに公開する。途中で kill されれば stamp は
存在せず、ゲートが half-state を弾く。stamp は world_size/tp_degree/dp_degree/shard_count を記録。

### P0-D: 冪等性 — `run-tasks.sh` + `qwen-image-edit-prepare.json`

- `run-tasks.sh` に `"always_run": true` タスクフィールドを追加。これを持つタスクは
  state file の fingerprint 一致で短絡されない（実スキップ判定はタスク内のガードに委ねる）。
- `40-compile` を `always_run: true` にし、冒頭で `.precompile_skipped`（=`10-skip-if-cached` が
  整合確認できたときだけ書く）を見て真のスキップ判定をする。
- `10-skip-if-cached` を「ディレクトリ存在」から「transformer に `.compile_stamp` があり
  shard 数 == stamp.tp_degree」へ強化。
- `40-compile` 末尾: compile.sh が exit 0 でも `.compile_stamp` が無ければ
  「不完全 compile」として publish を拒否。chown 失敗を WARN → **ハードエラー**化
  （root-0600 で ubuntu サーバが読めない CF-3 を根絶）。
- `50-verify` で `verify_artifacts.py` を実行し、serve と同一不変条件で publish をゲート。

### P1: EFS 永続化を正しく — `setup-efs-paths.json` + `qwen-image-edit-prepare.json`

CF-1/CF-4 の教訓: **live compile dir を EFS への symlink にしない**（mkdir EPERM と
サフィックス不一致の二重事故の元）。代わりに:

- `setup-efs-paths` `50-restore-compiled-models`: `_tp16` を**実 NVMe dir**として扱い、
  EFS に stamp 付き完成セットがあり NVMe が空のときだけ EFS→NVMe へ restore。
  旧構成の symlink は実 dir に置き換える。
- `qwen-image-edit-prepare` `60-persist-to-efs`: 検証済みセットを NVMe→EFS へ rsync 永続化。
  次回 recover が再コンパイル（90-120分）なしで restore できる。

### P2: ラテントリスク — `compile_transformer_v3_cfg.py`（未実装・任意）

`ModelBuilder(model=model)` 構築前に `NxDParallelState` コンテキスト内であることを
assert（CF-5）。今回未発火のため P2。

---

## 4. 検証手順

### 4-1. 整合性ゲート単体（実施済み・合格）

合成ディレクトリで `verify_artifacts.py` を検証:

| ケース | 期待 | 結果 |
|---|---|---|
| good（stamp ws32/tp16, 16 shards, config 一致） | exit 0 | ✅ |
| stale（stamp ws8 vs config ws32 = インシデント再現） | exit 1 | ✅ |
| shortshards（8 shards ≠ tp16） | exit 1 | ✅ |
| nostamp（中断/旧版） | exit 1 | ✅ |

### 4-2. キャッシュ分離（要実機）

1. `v3_cfg` でコンパイル → `neuron-compile-cache/v3_cfg/` に蓄積。
2. `v3_tp16` の `neuron-compile-cache/v3_tp16/` を空にして初回コンパイル → フル時間・32-rank。
3. `v3_tp16` 再実行 → `v3_tp16/` ヒット → 短時間・**32-rank**（正しい再利用）。
4. `v3_cfg` のキャッシュが `v3_tp16` の結果に影響しないことを確認。

### 4-3. 中断 → 復旧（half-state 防止、要実機・本番外）

1. `v3_tp16` コンパイルを起動し、`nxd_model.pt` 書き込み後に `SIGKILL`。
2. `verify_artifacts.py` 実行 → stamp 無しで exit 1。
3. `serve.py` 起動 → 起動時ゲートで早期失敗（`to_neuron()` 前）。
4. 再コンパイル → stamp 生成 → ゲート exit 0 → 正常起動。

### 4-4. state file スキップ防止（要実機）

1. `40-compile` 成功後、transformer を削除（stale を模す）。
2. `run-tasks.sh` 再実行 → `always_run` により "Already completed" にならず再コンパイル。

### 4-5. 権限（CF-3 再発防止、要実機）

compile 後 `stat .../weights/tp0_*.safetensors` が `ubuntu:ubuntu 0644` であること、
`sudo -u ubuntu` で safetensors を開けることを確認。

---

## 5. 注意 — 現行インスタンスの状態

インシデント収束後の正常な 32-rank 成果物は **NVMe (`/mnt/local`) のみ**に存在し、
本ドキュメントの P1（EFS 永続化）はコードに入ったが、現インスタンス上では
`60-persist-to-efs` を未実行。次回 instance 交換前に一度 `deploy-all.sh --recover`
（または prepare の `60-persist-to-efs` 単体）を流して EFS へ退避しておくこと。さもないと
交換時に 90-120 分の全再コンパイルが必要になる。
