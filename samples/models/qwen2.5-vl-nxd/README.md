# Qwen2.5-VL on Trainium2 via NxD Inference (`qwen2_5_vl` direct path)

A self-contained sample for running Qwen2.5-VL VLMs
(`Qwen/Qwen2.5-VL-7B-Instruct` and `stockmark/Stockmark-DocReasoner-Qwen2.5-VL-32B`)
directly on **NxD Inference (NxDI)** through the `HuggingFaceGenerationAdapter`,
without going through `vllm serve`.

The vLLM Neuron plugin (v0.16) does not yet ship `qwen2_5_vl` in its
`MODEL_TYPES` registry (only `qwen2_vl` and `qwen3_vl` are supported as of
2026-06), so `vllm serve` cannot load Qwen2.5-VL today. This sample uses
the NxDI direct path (`compile_qwen25vl.py`) which has been verified for
both the 7B and 32B variants.

Sister sample: `samples/models/qwen3-vl/` covers Qwen3-VL via vLLM Neuron.

## Verified configurations

| Model | HW | TP | LNC | Result |
|---|---|---|---|---|
| `Qwen/Qwen2.5-VL-7B-Instruct` | trn2.3xlarge | 2 | 2 | dummy gray + 3 real images all coherent |
| `stockmark/Stockmark-DocReasoner-Qwen2.5-VL-32B` | trn2.3xlarge | 8 | 1 | cos=0.999938 vs HF CPU, JP+EN sanity 6/6, avg greedy 93.75% |

## File layout

| File | Role |
|---|---|
| `modeling_qwen25vl.py` | Top-level VLM orchestrator (`NeuronStockmarkVLForCausalLM`). One `from_pretrained` that handles both the 7B flat config and the 32B nested-`text_config` layout, plus the split state-dict converter (vision + text). |
| `modeling_qwen25vl_text.py` | M-RoPE-aware text backbone. Forks Qwen2-VL, overrides `apply_rotary_embedding` to dodge the CTE→TKG `cos_cache` staleness, and strips the `model.*` weight prefix. |
| `modeling_qwen25vl_vision.py` | Qwen2.5-VL vision tower. `Qwen25RMSNorm` (weight-only) + `Qwen25VLVisionMlp` (SwiGLU 3-matrix), replacing Qwen2-VL's LayerNorm + 2-matrix GELU. |
| `compile_qwen25vl.py` | Compiles the 3 NEFFs (vision encoder + text CTE + text TKG) and runs a dummy gray smoke generate. |
| `sanity_qwen25vl.py` | 6-prompt text sanity (degeneracy + greedy match against HF CPU). |

## Environment

```text
# DLAMI-bundled venv (use the NxDI one, not the vLLM one)
/opt/aws_neuronx_venv_pytorch_2_9_nxd_inference

# Key packages (versions verified on the 2026-06 DLAMI)
neuronx_distributed_inference >= 0.10  # tested with 0.10.17970
torch == 2.9.x                         # tested with 2.9.1
torchvision == 0.24.x                  # tested with 0.24.1
transformers >= 4.51                   # tested with 4.57.6
```

`vLLM` itself is not required. Use the `*_nxd_inference` venv, not the
`*_vllm_*` one.

## Running on trn2.3xlarge with Qwen2.5-VL-7B-Instruct

```bash
cd samples/models/qwen2.5-vl-nxd

source /opt/aws_neuronx_venv_pytorch_2_9_nxd_inference/bin/activate

# LNC=2 (must be set for both runtime and compiler)
export NEURON_LOGICAL_NC_CONFIG=2
export NEURON_RT_VISIBLE_CORES=0-1
export NEURON_RT_NUM_CORES=2
export NEURON_CC_FLAGS="--target=trn2 --auto-cast=none --lnc=2"

# Compile + dummy gray smoke generate
HF_TOKEN=<your_hf_token> \
MODEL_ID=Qwen/Qwen2.5-VL-7B-Instruct \
TP_DEGREE=2 NUM_LAYERS=28 \
MAX_CONTEXT_LEN=1024 MAX_NEW_TOKENS=64 \
python compile_qwen25vl.py
# -> NEFFs land under traces/vl-28l/
# -> verdict + generated text in results/metrics-vl.json
```

## Running on trn2.3xlarge with Stockmark-DocReasoner-Qwen2.5-VL-32B

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

## Design notes (the gotchas you hit if you skip them)

### 1. `padding_side="right"` is mandatory (TIP-1039)

NxDI's `ModelWrapper.pad_inputs()` is **hardcoded to right-pad** and does
not look at `padding_side`. Combining `padding_side="left"` with
pre-applied left padding and a `masked_fill` correction breaks Japanese
generation within ~3 decode steps (e.g., `"質問われてきょ The question..."`).

`compile_qwen25vl.py` sets `padding_side="right"` on the NeuronConfig
explicitly and **does not override** `forward` / `prepare_inputs_for_generation`.

### 2. Self-implemented `from_pretrained` (TIP-1041)

NxDI's `ImageToTextInferenceConfig` does not provide `from_pretrained`.
`StockmarkVLInferenceConfig.from_pretrained` reads HF `config.json` and
builds `text_config` / `vision_config` directly. The same function handles
both the 7B **flat layout** (no `text_config`, fields like `hidden_size`
sit at the top level) and the 32B **nested layout**.

### 3. Vision config key remap (TIP-1042)

The HF Qwen2.5-VL `vision_config` uses different key names than NxDI's
Qwen2-VL base classes. Remap inside `modeling_qwen25vl.py:from_pretrained`:

| HF key | NxDI key | Notes |
|---|---|---|
| `in_chans` | `in_channels` | rename |
| `hidden_size` | `embed_dim` | duplicate |
| `intermediate_size / hidden_size` | `mlp_ratio` | computed |
| `out_hidden_size` | `hidden_size` (overwrite) | aligns the merger output dim with the text hidden_size |

### 4. M-RoPE `cos_cache` staleness mitigation

NxDI's `NeuronAttentionBase` propagates the CTE's `cos_cache` into TKG
steps. Because M-RoPE is position-dependent, the override
`apply_rotary_embedding` in `NeuronStockmarkTextAttention`
(`modeling_qwen25vl_text.py`) recomputes rotary every step.

### 5. Vision tower: RMSNorm + SwiGLU rewrite

Qwen2-VL → Qwen2.5-VL changed the vision encoder in two ways:

- `norm1` / `norm2` / `merger.ln_q`: LayerNorm (weight + bias) → RMSNorm
  (weight only)
- VisionBlock MLP: fc1 + GELU + fc2 → gate_proj + up_proj + down_proj
  (SwiGLU)

Loading a Qwen2.5-VL checkpoint into the upstream Qwen2-VL classes
produces a flood of `missing_keys` / `unexpected_keys`, leaving vision
embeddings as garbage. `modeling_qwen25vl_vision.py` provides Qwen2.5-VL
compatible replacements.

### 6. `eos_token_id=[151645, 151643]`

`<|im_end|>=151645` alone does not stop generation: you also need
`<|endoftext|>=151643`, otherwise generation runs to `max_new_tokens`.
`compile_qwen25vl.py` passes both in `GenerationConfig`.

### 7. `layer_types` double-truncate on `transformers >= 4.52`

When you reduce `num_hidden_layers`, you must truncate `layer_types`
both at the top level and inside `text_config`, otherwise validation
fails. See `_truncate_layers()`.

### 8. LNC2 needs both `--lnc=2` and `NEURON_LOGICAL_NC_CONFIG=2`

The runtime flag and the compiler flag are separate. Setting only one
side causes a runtime/compile LNC mismatch at load time.

## Sanity script (`sanity_qwen25vl.py`)

`sanity_qwen25vl.py` reloads a **text-only** NEFF and runs 6 prompts
(en/ja, 3 each) through both NxDI and the HF CPU reference.

Important: this script does NOT reuse the NEFFs produced by
`compile_qwen25vl.py` (which writes a VLM Application bundle to
`traces/vl-{N}l/`, with `text_model` wrapped inside the VLM). It expects a
**dedicated text-only NEFF** under `traces/text-{N}l/` (override with
`NEFF_DIR=...`). The text-only compile step is not bundled in this
sample; the EXP-1037 results referenced in the parent report were
produced by a separate text-only compile pass.

If you only need to verify the VLM pipeline end-to-end, the
`compile_qwen25vl.py` smoke generate (verdict A) is sufficient.

## Misc

- `num_kv_heads` is 4 (7B) or 8 (32B). Pick a TP that divides it
  evenly. `TP=8` on the 7B model triggers a `GQA → MHA` conversion
  inside NxDI, with measurable correctness drift; for the 7B variant
  prefer TP=2 or TP=4. NxDI may print
  `TP degree (2) and KV heads (4) are not divisible.` even for TP=2
  because its internal head-sharding heuristic is more conservative
  than a simple modulo; verdict=A confirms correctness was preserved
  in our run.
- After `python compile_qwen25vl.py` you will find:
  - NEFFs under `traces/vl-{NUM_LAYERS}l/`
  - verdict, generated text and latency in `results/metrics-vl.json`
  - on compile failure, the same JSON contains
    `{"status": "compile_fail", "error": "..."}`
