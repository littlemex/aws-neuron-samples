#!/usr/bin/env python3
"""Qwen2.5-VL VLM compile + smoke generate on AWS Trainium2 via NxD Inference.

Compiles 3 NEFFs (vision encoder + text CTE + text TKG) in a single pass via
NeuronStockmarkVLForCausalLM (which subclasses NxDI's NeuronQwen2VLForCausalLM)
and runs one dummy image + text prompt through HuggingFaceGenerationAdapter
to verify end-to-end VLM path.

Tested with:
  - Qwen/Qwen2.5-VL-7B-Instruct on trn2.3xlarge / TP=2 / LNC=2
  - stockmark/Stockmark-DocReasoner-Qwen2.5-VL-32B on trn2.3xlarge / TP=8 / LNC=1
    (cos=0.999938 vs HF CPU, 6/6 coherent on Japanese+English sanity)

Optional env vars:
  WORK_DIR          working directory for hf-ckpt-*l/, traces/, results/
                    (default: directory containing this script)
  MODEL_ID          HF repo id (default: Qwen/Qwen2.5-VL-7B-Instruct)
  HF_TOKEN          Hugging Face token (required for gated checkpoints)
  TP_DEGREE         tensor parallel degree (default: 2)
  NUM_LAYERS        text decoder layer count (default: 28)
  MAX_CONTEXT_LEN   text CTE max prompt length (default: 512)
  MAX_NEW_TOKENS    generation budget (default: 64)
  VISION_BUCKET     num-images bucket for vision NEFF (default: 1)
  IMAGE_W / IMAGE_H default image dims for vision NEFF sizing (default: 448x448)
  PROBE_PROMPT      text prompt for the smoke generate
"""
import os
import sys
import gc
import json
import time
import traceback
from pathlib import Path

# This sample places implementation files alongside the runner; add the script
# directory to sys.path so `import modeling_qwen25vl{,_text,_vision}` works.
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR))
WORK_DIR = Path(os.environ.get("WORK_DIR", str(SCRIPT_DIR)))

import torch
from PIL import Image
import numpy as np

from transformers import AutoConfig, AutoProcessor, Qwen2_5_VLForConditionalGeneration, GenerationConfig
from neuronx_distributed_inference.utils.hf_adapter import HuggingFaceGenerationAdapter

import modeling_qwen25vl_text as m_text
import modeling_qwen25vl as m_vl

MODEL_ID = os.environ.get("MODEL_ID", "Qwen/Qwen2.5-VL-7B-Instruct")
HF_TOKEN = os.environ.get("HF_TOKEN")
BATCH = 1
# Qwen2.5-VL-7B has num_kv_heads=4, so TP=8 leaves 0.5 head/core (not divisible).
# TP=4 (LNC=1) or TP=2 (LNC=2) are the safe choices. At TP=2 each NeuronCore gets ~9 GB.
TP_DEGREE = int(os.environ.get("TP_DEGREE", 2))

NUM_LAYERS = int(os.environ.get("NUM_LAYERS", 28))
MAX_CONTEXT_LEN = int(os.environ.get("MAX_CONTEXT_LEN", 512))
MAX_NEW_TOKENS = int(os.environ.get("MAX_NEW_TOKENS", 64))
SEQ_LEN = MAX_CONTEXT_LEN + MAX_NEW_TOKENS
VISION_BUCKET = int(os.environ.get("VISION_BUCKET", 1))  # num images per sample
IMAGE_W = int(os.environ.get("IMAGE_W", 448))
IMAGE_H = int(os.environ.get("IMAGE_H", 448))
PROBE_PROMPT = os.environ.get("PROBE_PROMPT", "What do you see in this image?")

HF_CKPT_DIR = Path(os.environ.get("HF_CKPT_DIR") or (WORK_DIR / f"hf-ckpt-{NUM_LAYERS}l"))
NEFF_DIR = WORK_DIR / "traces" / f"vl-{NUM_LAYERS}l"
RESULTS = WORK_DIR / "results"
NEFF_DIR.mkdir(parents=True, exist_ok=True)
RESULTS.mkdir(parents=True, exist_ok=True)

print("=" * 60)
print(f"Qwen2.5-VL: compile 3 NEFFs (vision encoder + text CTE + text TKG)")
print(f"  MODEL_ID={MODEL_ID}  TP_DEGREE={TP_DEGREE}")
print(f"  NUM_LAYERS={NUM_LAYERS}  MAX_CONTEXT_LEN={MAX_CONTEXT_LEN}  "
      f"MAX_NEW_TOKENS={MAX_NEW_TOKENS}  SEQ_LEN={SEQ_LEN}")
print(f"  VISION_BUCKET={VISION_BUCKET}  IMAGE={IMAGE_W}x{IMAGE_H}")
print("=" * 60)


def _truncate_layers(cfg, n):
    """Truncate num_hidden_layers and layer_types on Qwen2.5-VL config (both top + text_config)."""
    if hasattr(cfg, "num_hidden_layers"):
        cfg.num_hidden_layers = n
    if hasattr(cfg, "layer_types") and cfg.layer_types is not None:
        cfg.layer_types = list(cfg.layer_types)[:n]
    if hasattr(cfg, "text_config") and cfg.text_config is not None:
        tc = cfg.text_config
        if hasattr(tc, "num_hidden_layers"):
            tc.num_hidden_layers = n
        if hasattr(tc, "layer_types") and tc.layer_types is not None:
            tc.layer_types = list(tc.layer_types)[:n]
    return cfg


# ---------------------------------------------------------------------------
# Step 1: ensure HF checkpoint is saved with the desired num_hidden_layers
# (re-uses hf-ckpt-{N}l/ from the text-only experiment if it exists; the
# checkpoint includes both text and vision weights)
# ---------------------------------------------------------------------------
if not (HF_CKPT_DIR / "config.json").exists():
    print(f"[HF] downloading full Qwen2.5-VL + truncating layers -> {NUM_LAYERS}")
    t0 = time.time()
    hf_config = AutoConfig.from_pretrained(MODEL_ID, token=HF_TOKEN)
    _truncate_layers(hf_config, NUM_LAYERS)
    hf_model = Qwen2_5_VLForConditionalGeneration.from_pretrained(
        MODEL_ID, config=hf_config, torch_dtype=torch.bfloat16,
        low_cpu_mem_usage=True, token=HF_TOKEN,
    ).eval().cpu()
    hf_model.save_pretrained(str(HF_CKPT_DIR), safe_serialization=True)

    # round-trip layer_types truncation on the saved JSON
    cfg_path = HF_CKPT_DIR / "config.json"
    cfg_dict = json.loads(cfg_path.read_text())
    def _trunc_dict(d, n):
        if "num_hidden_layers" in d:
            d["num_hidden_layers"] = n
        if "layer_types" in d and isinstance(d["layer_types"], list):
            d["layer_types"] = d["layer_types"][:n]
    _trunc_dict(cfg_dict, NUM_LAYERS)
    if "text_config" in cfg_dict and isinstance(cfg_dict["text_config"], dict):
        _trunc_dict(cfg_dict["text_config"], NUM_LAYERS)
    cfg_path.write_text(json.dumps(cfg_dict, indent=2))

    del hf_model
    gc.collect()
    print(f"[HF] saved to {HF_CKPT_DIR} in {time.time()-t0:.1f}s")
else:
    print(f"[HF] reusing checkpoint at {HF_CKPT_DIR}")


# ---------------------------------------------------------------------------
# Step 2: build text + vision NeuronConfigs
# ---------------------------------------------------------------------------
print("[NxD] building StockmarkVL configs...")

text_nc_kwargs = dict(
    tp_degree=TP_DEGREE,
    logical_nc_config=1,
    torch_dtype=torch.bfloat16,
    batch_size=BATCH,
    seq_len=SEQ_LEN,
    max_context_length=MAX_CONTEXT_LEN,
    n_positions=SEQ_LEN,
    max_new_tokens=MAX_NEW_TOKENS,
    max_length=SEQ_LEN,
    on_device_sampling_config=None,
    vocab_parallel=False,
    fused_qkv=False,
    padding_side="right",
)
text_nc = m_text.StockmarkTextNeuronConfig(**text_nc_kwargs)

# Qwen2VLInferenceConfig asserts vision_config.fused_qkv is True, so do not
# disable here. Vision weight-conversion routes qkv -> qkv_proj.Wqkv.
vision_nc = m_vl.StockmarkVLNeuronConfig(
    tp_degree=TP_DEGREE,
    logical_nc_config=1,
    torch_dtype=torch.bfloat16,
    batch_size=BATCH,
    seq_len=SEQ_LEN,          # vision pad_to_text_seq_len targets this
    buckets=[VISION_BUCKET],   # num images per sample
    default_image_width=IMAGE_W,
    default_image_height=IMAGE_H,
    fused_qkv=True,            # required by Qwen2VLInferenceConfig
)

vl_config = m_vl.StockmarkVLInferenceConfig.from_pretrained(
    str(HF_CKPT_DIR),
    text_neuron_config=text_nc,
    vision_neuron_config=vision_nc,
)
print(f"[NxD] hidden={vl_config.text_config.hidden_size} "
      f"text_layers={vl_config.text_config.num_hidden_layers} "
      f"vision_depth={vl_config.vision_config.depth} "
      f"vision_embed_dim={vl_config.vision_config.embed_dim} "
      f"patch_size={vl_config.vision_config.patch_size}")


# ---------------------------------------------------------------------------
# Step 3: construct + compile
# ---------------------------------------------------------------------------
compiled_path = str(NEFF_DIR)
SKIP_COMPILE = os.environ.get("SKIP_COMPILE", "0") == "1" or any(
    NEFF_DIR.glob("*/model.pt")
)

try:
    vl_model = m_vl.NeuronStockmarkVLForCausalLM(
        model_path=str(HF_CKPT_DIR), config=vl_config,
    )
    print(f"[NxD] constructed, models count={len(vl_model.models)}, "
          f"vision_models count={len(vl_model.vision_models)}")
    for mdl in vl_model.models:
        print(f"  - text tag={mdl.tag} n_active={mdl.neuron_config.n_active_tokens}")
    for mdl in vl_model.vision_models:
        print(f"  - vision tag={mdl.tag} buckets={mdl.config.vision_config.neuron_config.buckets}")
except Exception as e:
    print(f"[NxD] construction FAILED: {type(e).__name__}: {e}")
    traceback.print_exc(limit=25)
    sys.exit(1)

if SKIP_COMPILE:
    print(f"[NxD] compile SKIPPED (existing NEFFs under {compiled_path}, reuse)")
    t_compile = 0.0
else:
    print(f"[NxD] compile -> {compiled_path} (3 NEFFs: vision + text CTE + text TKG)")
    t2 = time.time()
    try:
        vl_model.compile(compiled_path)
        t_compile = time.time() - t2
        print(f"[NxD] compile PASS {t_compile:.1f}s ({t_compile/60:.2f} min)")
    except Exception as e:
        print(f"[NxD] compile FAILED: {type(e).__name__}: {e}")
        traceback.print_exc(limit=30)
        (RESULTS / "metrics-vl.json").write_text(json.dumps({
            "status": "compile_fail", "error": f"{type(e).__name__}: {e}",
        }, indent=2))
        sys.exit(2)

print(f"[NxD] load + load_weights ...")
t3 = time.time()
try:
    vl_model.load(compiled_path)
    print(f"[NxD] load PASS {time.time()-t3:.1f}s")
except Exception as e:
    print(f"[NxD] load FAILED: {type(e).__name__}: {e}")
    traceback.print_exc(limit=20)
    sys.exit(3)


# ---------------------------------------------------------------------------
# Step 4: smoke generate with a synthetic image
# ---------------------------------------------------------------------------
print("[GEN] loading processor + building dummy image input ...")
processor = AutoProcessor.from_pretrained(MODEL_ID, token=HF_TOKEN)

# Simple dummy image: a 448x448 grey square. Qwen2.5-VL processor will resize
# to a valid grid (multiples of 14*2) so grid_thw should land at [1, 32, 32]
# -> 1024 patches, which matches pixels_per_image for VISION_BUCKET=1.
dummy_img = Image.fromarray(np.full((IMAGE_H, IMAGE_W, 3), 128, dtype=np.uint8))

messages = [{
    "role": "user",
    "content": [
        {"type": "image"},
        {"type": "text", "text": PROBE_PROMPT},
    ],
}]
prompt_text = processor.apply_chat_template(
    messages, tokenize=False, add_generation_prompt=True,
)
inputs = processor(
    text=[prompt_text], images=[dummy_img],
    return_tensors="pt", padding=True,
)
print(f"[GEN] input_ids.shape={inputs.input_ids.shape} "
      f"pixel_values.shape={tuple(inputs.pixel_values.shape)} "
      f"image_grid_thw={inputs.image_grid_thw.tolist()}")

adapter = HuggingFaceGenerationAdapter(vl_model)
gen_config = GenerationConfig(
    max_new_tokens=MAX_NEW_TOKENS,
    do_sample=False,
    repetition_penalty=1.05,
    pad_token_id=processor.tokenizer.pad_token_id,
    eos_token_id=[151645, 151643],
)

t4 = time.time()
try:
    with torch.no_grad():
        out_ids = adapter.generate(
            inputs.input_ids,
            attention_mask=inputs.attention_mask,
            pixel_values=inputs.pixel_values,
            image_grid_thw=inputs.image_grid_thw,
            generation_config=gen_config,
        )
    print(f"[GEN] done {time.time()-t4:.1f}s out.shape={tuple(out_ids.shape)}")
except Exception as e:
    print(f"[GEN] FAILED: {type(e).__name__}: {e}")
    traceback.print_exc(limit=30)
    sys.exit(4)

new_tokens = out_ids[0, inputs.input_ids.shape[-1]:]
gen_text = processor.tokenizer.decode(new_tokens, skip_special_tokens=True)
full_text = processor.tokenizer.decode(out_ids[0], skip_special_tokens=True)

print("=" * 60)
print(f"[GEN] full: {full_text!r}")
print(f"[GEN] tail: {gen_text!r}")
print("=" * 60)

metrics = {
    "model": MODEL_ID,
    "num_layers": NUM_LAYERS,
    "tp_degree": TP_DEGREE,
    "max_context_len": MAX_CONTEXT_LEN,
    "max_new_tokens": MAX_NEW_TOKENS,
    "vision_bucket": VISION_BUCKET,
    "image_w": IMAGE_W, "image_h": IMAGE_H,
    "compile_time_sec": round(t_compile, 2),
    "status": "pass",
    "probe_prompt": PROBE_PROMPT,
    "pixel_values_shape": list(inputs.pixel_values.shape),
    "image_grid_thw": inputs.image_grid_thw.tolist(),
    "prompt_len": int(inputs.input_ids.shape[-1]),
    "num_image_pad_tokens": int((inputs.input_ids == 151655).sum().item()),
    "gen_new_tokens": new_tokens.tolist(),
    "gen_full_text": full_text,
    "gen_tail_text": gen_text,
}

# Degeneracy check: >=6 consecutive identical tokens
new_list = new_tokens.tolist()
degenerate = any(
    len(set(new_list[i:i+6])) == 1 for i in range(len(new_list) - 5)
) if len(new_list) >= 6 else False
metrics["degenerate"] = degenerate

if degenerate:
    metrics["verdict"] = "B: generation degenerate (repeating tokens)"
elif len(gen_text.strip()) == 0:
    metrics["verdict"] = "C: empty generation"
else:
    metrics["verdict"] = "A: VLM generates coherent text for dummy image"

(RESULTS / "metrics-vl.json").write_text(
    json.dumps(metrics, indent=2, ensure_ascii=False)
)
print(f"[METRICS] {RESULTS}/metrics-vl.json")
print(f"[VERDICT] {metrics['verdict']}")
