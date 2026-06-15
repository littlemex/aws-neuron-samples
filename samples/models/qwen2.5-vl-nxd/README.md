# Qwen2.5-VL on Trainium2 via NxD Inference (`qwen2_5_vl` direct path)

Qwen2.5-VL 系列 VLM (`Qwen/Qwen2.5-VL-7B-Instruct` / `stockmark/Stockmark-DocReasoner-Qwen2.5-VL-32B`)
を **NxD Inference (NxDI)** から `HuggingFaceGenerationAdapter` 経由で直接動かすサンプル。

vLLM Neuron plugin (v0.16) は 2026-06 時点で `qwen2_5_vl` を未サポートのため、 vLLM serve
経由ではなく NxDI を直接叩くこのパス (`compile_qwen25vl.py`) で 7B / 32B のいずれも
動作確認済み。

姉妹サンプル: `samples/models/qwen3-vl/` は vLLM Neuron 経由の Qwen3-VL を扱う。

## 動作確認済み構成

| モデル | HW | TP | LNC | 結果 |
|---|---|---|---|---|
| `Qwen/Qwen2.5-VL-7B-Instruct` | trn2.3xlarge | 2 | 2 | dummy gray + real 3 image いずれも coherent |
| `stockmark/Stockmark-DocReasoner-Qwen2.5-VL-32B` | trn2.3xlarge | 8 | 1 | cos=0.999938 / 日英 sanity 6/6 / avg greedy 93.75% |

## ファイル構成

| ファイル | 役割 |
|---|---|
| `modeling_qwen25vl.py` | top-level VLM orchestrator (`NeuronStockmarkVLForCausalLM`)。 7B flat config + Stockmark ネスト config 双方に対応した `from_pretrained`、 vision/text の weight 変換ルート分割 |
| `modeling_qwen25vl_text.py` | M-RoPE 対応 text backbone。 Qwen2-VL を fork し、 `apply_rotary_embedding` を override して CTE→TKG の cos_cache stale を回避、 weight key prefix `model.*` を strip |
| `modeling_qwen25vl_vision.py` | Qwen2.5-VL 系 vision tower。 `Qwen25RMSNorm` (weight-only) + `Qwen25VLVisionMlp` (SwiGLU 3-matrix)。 Qwen2-VL の LayerNorm + 2-matrix GELU を上書き |
| `compile_qwen25vl.py` | 3 NEFF (vision encoder + text CTE + text TKG) compile + dummy gray smoke generate |
| `sanity_qwen25vl.py` | text NEFF 用 6 prompt sanity (degeneracy + greedy match vs HF CPU) |

## 必要環境

```text
# DLAMI 同梱 venv のいずれか
/opt/aws_neuronx_venv_pytorch_2_9_nxd_inference

# 主要パッケージ
neuronx_distributed_inference >= 0.10
torch == 2.9.x
torchvision == 0.24.x
transformers >= 4.51, < 4.53
```

`vLLM` は不要。 vLLM 専用 venv (`*_vllm_*`) ではなく `*_nxd_inference` を使う。

## 起動 (trn2.3xlarge / Qwen2.5-VL-7B-Instruct)

```bash
cd samples/models/qwen2.5-vl-nxd

source /opt/aws_neuronx_venv_pytorch_2_9_nxd_inference/bin/activate

# LNC=2 設定 (runtime + compiler 両方必須)
export NEURON_LOGICAL_NC_CONFIG=2
export NEURON_RT_VISIBLE_CORES=0-1
export NEURON_RT_NUM_CORES=2
export NEURON_CC_FLAGS="--target=trn2 --auto-cast=none --lnc=2"

# 動作確認 (compile + dummy gray smoke generate)
HF_TOKEN=<your_hf_token> \
MODEL_ID=Qwen/Qwen2.5-VL-7B-Instruct \
TP_DEGREE=2 NUM_LAYERS=28 \
MAX_CONTEXT_LEN=1024 MAX_NEW_TOKENS=64 \
python compile_qwen25vl.py
# -> traces/vl-28l/ に NEFF
# -> results/metrics-vl.json に verdict
```

## 起動 (trn2.3xlarge / Stockmark-DocReasoner-Qwen2.5-VL-32B)

```bash
source /opt/aws_neuronx_venv_pytorch_2_9_nxd_inference/bin/activate
export NEURON_LOGICAL_NC_CONFIG=1
export NEURON_RT_VISIBLE_CORES=0-7
export NEURON_RT_NUM_CORES=8
export NEURON_CC_FLAGS="--target=trn2 --auto-cast=none --lnc=1"

HF_TOKEN=<your_hf_token> \
MODEL_ID=stockmark/Stockmark-DocReasoner-Qwen2.5-VL-32B \
TP_DEGREE=8 NUM_LAYERS=64 \
MAX_CONTEXT_LEN=512 MAX_NEW_TOKENS=64 \
python compile_qwen25vl.py
```

## 重要な設計判断 (踏まないと壊れる落とし穴)

### 1. `padding_side="right"` 必須 (TIP-1039)

NxDI の `ModelWrapper.pad_inputs()` は **hardcoded right-pad** で `padding_side` を参照しない。
`padding_side="left"` + 事前 left-pad + masked_fill で組むと、 日本語 prompt が 3 step で
壊れる (例: `"質問われてきょ The question..."`)。

`compile_qwen25vl.py` では NeuronConfig に `padding_side="right"` を明示し、
`forward` / `prepare_inputs_for_generation` の override は **書かない**。

### 2. `from_pretrained` 自前実装 (TIP-1041)

NxDI の `ImageToTextInferenceConfig` には `from_pretrained` が無い。
`StockmarkVLInferenceConfig.from_pretrained` で HF `config.json` を読み、 text_config /
vision_config を組み立てる。 7B の **flat config layout** (`text_config` が無く top-level に
hidden_size 等が並ぶ) と 32B の **ネスト layout** の両方を 1 関数で扱う。

### 3. Vision config key remap 4 箇所 (TIP-1042)

HF Qwen2.5-VL の vision_config と NxDI Qwen2-VL ベースクラスで key 名が違う。
`modeling_qwen25vl.py:from_pretrained` 内で remap:

| HF key | NxDI key | 備考 |
|---|---|---|
| `in_chans` | `in_channels` | rename |
| `hidden_size` | `embed_dim` | duplicate |
| `intermediate_size / hidden_size` | `mlp_ratio` | 計算 |
| `out_hidden_size` | `hidden_size` (上書き) | merger 出力次元を text hidden に揃える |

### 4. M-RoPE cos_cache stale 回避

NxDI の `NeuronAttentionBase` は CTE の `cos_cache` を TKG ステップに引き継ぐ。
M-RoPE は position-dependent なので毎ステップ rotary を再計算する `apply_rotary_embedding`
override を入れてある (`modeling_qwen25vl_text.py:NeuronStockmarkTextAttention`)。

### 5. Vision tower の RMSNorm + SwiGLU 刷新

Qwen2-VL → Qwen2.5-VL で vision encoder が以下のように変わった:

- `norm1` / `norm2` / `merger.ln_q`: LayerNorm (weight + bias) → RMSNorm (weight only)
- VisionBlock MLP: fc1 + GELU + fc2 → gate_proj + up_proj + down_proj (SwiGLU)

NxDI 公式の Qwen2-VL クラスをそのまま使うと missing_keys / unexpected_keys が大量発生し、
vision embedding が garbage になる。 `modeling_qwen25vl_vision.py` で Qwen2.5-VL 互換に
差し替え。

### 6. `eos_token_id=[151645, 151643]`

`<|im_end|>=151645` だけでは止まらず `<|endoftext|>=151643` まで含めないと max_new_tokens
まで走り切る。 `compile_qwen25vl.py` の GenerationConfig に両方を渡す。

### 7. `transformers >= 4.52` の `layer_types` 二重 truncate

`num_hidden_layers` を縮める場合、 top-level と `text_config` の両方の `layer_types` を
切る必要がある。 `_truncate_layers()` を参照。

### 8. LNC2 は `--lnc=2` と `NEURON_LOGICAL_NC_CONFIG=2` の両方が必要

runtime flag と compiler flag は別系統。 片方だけだと load 時に LNC 不一致でエラーになる。

## 補足

- `num_kv_heads` は 7B = 4 / 32B = 8 で、 TP は割り切れる値だけが安全。 TP=8 は 7B では
  GQA→MHA 変換が走り correctness drift する。 7B では TP=2 か TP=4 を推奨。
- 結果は `results/metrics-vl.json` (vision smoke) と `results/sanity-generate.json`
  (text 6 prompt) に保存される。
- compile + smoke 実行後は `traces/vl-{NUM_LAYERS}l/` に NEFF が、 `results/metrics-vl.json` に
  verdict / 生成テキスト / latency が保存される。
