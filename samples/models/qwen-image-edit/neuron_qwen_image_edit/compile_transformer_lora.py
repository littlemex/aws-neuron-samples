import gc
"""
Transformer compilation with LoRA weights merged into base model.

Loads the base Qwen-Image-Edit model, applies LoRA weights from
JamesDigitalOcean/Qwen_Image_Edit_Try_On_Clothes, merges them into
the transformer, then compiles using the same V3 CFG pipeline.

The LoRA only modifies the transformer (diffusion model), so VAE,
vision encoder, and language model can be reused from base compilation.

Usage:
    python compile_transformer_lora.py \
        --height 1024 --width 512 \
        --tp_degree 16 --world_size 32 \
        --patch_multiplier 3 \
        --compiled_models_dir /opt/dlami/nvme/compiled_models_lora
"""

import os
import json
import math
import sys

os.environ["NEURON_FUSE_SOFTMAX"] = "1"
os.environ["NEURON_CUSTOM_SILU"] = "1"
os.environ["XLA_DISABLE_FUNCTIONALIZATION"] = "1"
os.environ["NEURON_RT_VIRTUAL_CORE_SIZE"] = "2"
os.environ["NEURON_LOGICAL_NC_CONFIG"] = "2"

compiler_flags = """ --target=trn2 --lnc=2 --model-type=transformer --auto-cast=none --enable-fast-loading-neuron-binaries --tensorizer-options='--enable-ccop-compute-overlap' --internal-hlo2tensorizer-options='--enable-state-buffer-mode=hybrid --remat-by-default' """
os.environ["NEURON_CC_FLAGS"] = os.environ.get("NEURON_CC_FLAGS", "") + compiler_flags

import torch
import torch.nn as nn
import argparse

from diffusers import QwenImageEditPlusPipeline
from huggingface_hub import hf_hub_download
from safetensors.torch import load_file

from neuronx_distributed import ModelBuilder, NxDParallelState, shard_checkpoint
from neuronx_distributed.parallel_layers.layers import (
    ColumnParallelLinear,
    RowParallelLinear,
    SPMDRank,
)
from neuronx_distributed.parallel_layers import parallel_state

from neuron_parallel_utils import (
    shard_qwen_attention,
    shard_feedforward,
    shard_modulation,
    get_sharded_data,
)

# Import from the existing V3 CFG compile script (reuse all the Neuron classes)
from compile_transformer_v3_cfg import (
    NeuronQwenTransformerV3CFG,
    TracingWrapper,
    get_rope_from_original_model,
)

CACHE_DIR = "/opt/dlami/nvme/qwen_image_edit_hf_cache_dir"
BASE_MODEL_ID = "Qwen/Qwen-Image-Edit-2509"
LORA_MODEL_ID = "JamesDigitalOcean/Qwen_Image_Edit_Try_On_Clothes"
LORA_FILENAME = "qwen_image_edit_tryon.safetensors"
LORA_CACHE_DIR = "/opt/dlami/nvme/lora_cache"


def load_and_merge_lora(pipe, lora_weight_path):
    """
    Load LoRA weights and merge them into the transformer.
    Tries diffusers built-in API first, falls back to manual merge.
    """
    print(f"\nLoading LoRA weights from: {lora_weight_path}")
    lora_state = load_file(lora_weight_path)
    print(f"  LoRA contains {len(lora_state)} tensors")

    # Try diffusers' built-in LoRA loading first
    try:
        print("  Attempting diffusers load_lora_weights...")
        pipe.load_lora_weights(lora_weight_path)
        print("  LoRA loaded via diffusers API")

        print("  Fusing LoRA into transformer weights...")
        pipe.fuse_lora()
        print("  LoRA fused successfully!")

        pipe.unload_lora_weights()
        print("  LoRA adapters unloaded (weights are merged)")
        return
    except Exception as e:
        print(f"  diffusers API failed: {e}")
        print("  Falling back to manual LoRA merge...")

    # Manual merge fallback
    lora_pairs = {}
    for key in lora_state:
        if "lora_A" in key:
            base_key = key.replace(".lora_A.weight", "").replace("lora_A.", "")
            lora_pairs.setdefault(base_key, {})["A"] = lora_state[key]
        elif "lora_B" in key:
            base_key = key.replace(".lora_B.weight", "").replace("lora_B.", "")
            lora_pairs.setdefault(base_key, {})["B"] = lora_state[key]
        elif "alpha" in key:
            base_key = key.replace(".alpha", "")
            lora_pairs.setdefault(base_key, {})["alpha"] = lora_state[key].item()

    print(f"  Found {len(lora_pairs)} LoRA layer pairs")

    transformer_state = pipe.transformer.state_dict()
    merged_count = 0

    for lora_key, pair in lora_pairs.items():
        if "A" not in pair or "B" not in pair:
            continue

        A = pair["A"].to(torch.bfloat16)
        B = pair["B"].to(torch.bfloat16)
        alpha = pair.get("alpha", A.shape[0])
        scale = alpha / A.shape[0]

        # Find matching key in transformer state dict
        search_key = lora_key.replace("transformer.", "").replace("diffusion_model.", "")
        target_key = None
        for tk in transformer_state:
            if tk == search_key or tk.endswith(search_key):
                target_key = tk
                break
        if target_key is None:
            for tk in transformer_state:
                clean = search_key.replace(".weight", "")
                if tk == clean + ".weight":
                    target_key = tk
                    break
        if target_key is None:
            print(f"  WARNING: No match for LoRA key '{lora_key}', skipping")
            continue

        W = transformer_state[target_key]
        delta = (B @ A) * scale
        transformer_state[target_key] = W + delta.to(W.dtype)
        merged_count += 1

    print(f"  Merged {merged_count} LoRA layers into transformer")
    pipe.transformer.load_state_dict(transformer_state)
    print("  Transformer updated with merged LoRA weights")


def compile_transformer_lora(args):
    """Compile transformer with LoRA merged, using V3 CFG pipeline."""

    tp_degree = args.tp_degree
    world_size = args.world_size
    cfg_parallel_enabled = (world_size != tp_degree)
    dp_degree = world_size // tp_degree if cfg_parallel_enabled else 1

    if cfg_parallel_enabled:
        print(f"CFG Parallel enabled: DP={dp_degree}")

    latent_h = args.height // 8
    latent_w = args.width // 8
    patch_size = 2
    patch_h = latent_h // patch_size
    patch_w = latent_w // patch_size
    temporal_frames = args.patch_multiplier
    num_patches = temporal_frames * patch_h * patch_w
    text_seq_len = args.max_sequence_length

    text_hidden_size = 3584
    in_channels = 64
    head_dim = 128

    total_seq = num_patches + text_seq_len
    alignment = 128
    need_padding = (alignment - total_seq % alignment) % alignment
    num_patches_padded = num_patches + need_padding
    patches_padding = need_padding

    batch_size = 2

    print("=" * 60)
    print("Transformer V3 CFG + LoRA Compilation")
    print("=" * 60)
    print(f"Base model: {BASE_MODEL_ID}")
    print(f"LoRA: {LORA_MODEL_ID}")
    print(f"Image: {args.height}x{args.width}")
    print(f"Original patches: {num_patches}")
    if patches_padding > 0:
        print(f"Padded patches: {num_patches_padded} (+{patches_padding} for alignment)")
    print(f"Total seq (padded): {num_patches_padded + text_seq_len}")
    print(f"TP degree: {tp_degree}")
    print(f"World size: {world_size}")
    print(f"CFG Parallel: {cfg_parallel_enabled} (DP={dp_degree})")
    print(f"Batch size: {batch_size} (hard-coded for CFG)")

    sample_hidden_states = torch.randn(batch_size, num_patches_padded, in_channels, dtype=torch.bfloat16)
    sample_encoder_hidden_states = torch.randn(batch_size, text_seq_len, text_hidden_size, dtype=torch.bfloat16)
    sample_timestep = torch.randn(batch_size, dtype=torch.float32)

    with NxDParallelState(world_size=world_size, tensor_model_parallel_size=tp_degree):
        print("\nLoading base model...")
        load_kwargs = {"torch_dtype": torch.bfloat16, "local_files_only": True}
        if CACHE_DIR:
            load_kwargs["cache_dir"] = CACHE_DIR
        pipe = QwenImageEditPlusPipeline.from_pretrained(BASE_MODEL_ID, **load_kwargs)

        # Download and merge LoRA
        lora_path = hf_hub_download(
            repo_id=LORA_MODEL_ID,
            filename=LORA_FILENAME,
            cache_dir=LORA_CACHE_DIR
        )
        load_and_merge_lora(pipe, lora_path)

        print("\nGetting RoPE...")
        img_rotary_emb, txt_rotary_emb = get_rope_from_original_model(
            pipe=pipe, frame=temporal_frames,
            height=patch_h, width=patch_w, text_seq_len=text_seq_len,
        )
        print(f"  img RoPE (original): {img_rotary_emb.shape}")
        print(f"  txt RoPE: {txt_rotary_emb.shape}")

        if patches_padding > 0:
            rope_padding = img_rotary_emb[-1:].repeat(patches_padding, 1, 1)
            img_rotary_emb = torch.cat([img_rotary_emb, rope_padding], dim=0)
            print(f"  img RoPE (padded): {img_rotary_emb.shape} (+{patches_padding})")

        unsharded_state = pipe.transformer.state_dict()

        print("\nCreating Neuron transformer (TP={}, world_size={})...".format(tp_degree, world_size))
        neuron_transformer = NeuronQwenTransformerV3CFG(
            pipe.transformer, tp_degree, world_size, cfg_parallel_enabled
        )
        neuron_transformer = neuron_transformer.to(torch.bfloat16)
        neuron_transformer.eval()

        model = TracingWrapper(neuron_transformer)

        print("\nInitializing ModelBuilder...")
        builder = ModelBuilder(model=model)

        print("Tracing model...")
        builder.trace(
            kwargs={
                "hidden_states": sample_hidden_states,
                "encoder_hidden_states": sample_encoder_hidden_states,
                "timestep": sample_timestep,
                "img_rotary_emb": img_rotary_emb,
                "txt_rotary_emb": txt_rotary_emb,
            },
            tag="inference",
        )

        print("Compiling model...")
        compile_args = "--model-type=transformer -O1 --auto-cast=none --internal-hlo2tensorizer-options='--enable-native-kernel=1 --remat'"
        traced_model = builder.compile(
            compiler_args=compile_args,
            compiler_workdir=args.compiler_workdir,
        )

        output_path = f"{args.compiled_models_dir}/transformer_v3_cfg"
        os.makedirs(output_path, exist_ok=True)

        print(f"\nSaving to {output_path}...")
        traced_model.save(os.path.join(output_path, "nxd_model.pt"))

        # Save weights
        weights_path = os.path.join(output_path, "weights")
        os.makedirs(weights_path, exist_ok=True)

        checkpoint = {}
        global_rank_state = {}

        orig_num_heads = pipe.transformer.config.num_attention_heads
        from neuronx_distributed.parallel_layers.pad import get_number_of_extra_heads
        extra_heads = get_number_of_extra_heads(orig_num_heads, tp_degree)
        head_dim_val = 128
        orig_attn_dim = orig_num_heads * head_dim_val
        padded_attn_dim = (orig_num_heads + extra_heads) * head_dim_val
        need_attn_pad = extra_heads > 0
        if need_attn_pad:
            print(f"  Padding attention weights: {orig_attn_dim} -> {padded_attn_dim} ({extra_heads} extra heads)")

        attn_out_pad_suffixes = ('.to_q.weight', '.to_q.bias', '.to_k.weight', '.to_k.bias',
                                 '.to_v.weight', '.to_v.bias',
                                 '.add_q_proj.weight', '.add_q_proj.bias',
                                 '.add_k_proj.weight', '.add_k_proj.bias',
                                 '.add_v_proj.weight', '.add_v_proj.bias')
        attn_in_pad_suffixes = ('.to_out.0.weight', '.to_add_out.weight')

        for key, value in model.state_dict().items():
            if 'global_rank' in key:
                global_rank_state[key] = value.clone()
                continue
            orig_key = key.replace("transformer.", "", 1)
            if orig_key in unsharded_state:
                w = unsharded_state[orig_key].clone()
            else:
                w = value.clone()

            if need_attn_pad:
                if any(key.endswith(s) for s in attn_out_pad_suffixes):
                    pad_size = padded_attn_dim - w.shape[0]
                    if pad_size > 0:
                        if w.dim() == 2:
                            w = torch.cat([w, torch.zeros(pad_size, w.shape[1], dtype=w.dtype)], dim=0)
                        else:
                            w = torch.cat([w, torch.zeros(pad_size, dtype=w.dtype)], dim=0)
                elif any(key.endswith(s) for s in attn_in_pad_suffixes):
                    pad_size = padded_attn_dim - w.shape[1]
                    if pad_size > 0:
                        w = torch.cat([w, torch.zeros(w.shape[0], pad_size, dtype=w.dtype)], dim=1)

            checkpoint[key] = w

        print("Sharding weights...")
        shard_checkpoint(checkpoint=checkpoint, model=model, serialize_path=weights_path)

        print("\nPost-processing sharded checkpoints...")
        from safetensors.torch import load_file as load_safetensors, save_file
        for rank in range(tp_degree):
            shard_file = os.path.join(weights_path, f"tp{rank}_sharded_checkpoint.safetensors")
            if not os.path.exists(shard_file):
                print(f"  WARNING: {shard_file} not found")
                continue

            shard_data = dict(load_safetensors(shard_file))
            original_count = len(shard_data)
            original_size = sum(v.numel() * v.element_size() for v in shard_data.values())

            cleaned = {k: v for k, v in shard_data.items() if 'master_weight' not in k}
            if global_rank_state:
                cleaned.update(global_rank_state)

            cleaned_size = sum(v.numel() * v.element_size() for v in cleaned.values())
            # patched: atomic save (mmap-safe)
            _tmp_file = shard_file + ".tmp"
            save_file(cleaned, _tmp_file)
            try:
                del data
            except Exception:
                pass
            gc.collect()
            os.replace(_tmp_file, shard_file)
            print(f"  tp{rank}: {original_count} -> {len(cleaned)} tensors, "
                  f"{original_size/1e9:.2f}GB -> {cleaned_size/1e9:.2f}GB")

        config = {
            "height": args.height,
            "width": args.width,
            "num_patches": num_patches,
            "num_patches_padded": num_patches_padded,
            "patches_padding": patches_padding,
            "text_seq_len": text_seq_len,
            "patch_multiplier": args.patch_multiplier,
            "tp_degree": tp_degree,
            "world_size": world_size,
            "cfg_parallel": cfg_parallel_enabled,
            "dp_degree": dp_degree,
            "head_dim": head_dim,
            "frame": temporal_frames,
            "patch_h": patch_h,
            "patch_w": patch_w,
            "nki_flash_attention": True,
            "batch_size": batch_size,
            "lora_model": LORA_MODEL_ID,
        }
        with open(os.path.join(output_path, "config.json"), "w") as f:
            json.dump(config, f, indent=2)

        torch.save({
            "img_rotary_emb": img_rotary_emb,
            "txt_rotary_emb": txt_rotary_emb,
        }, os.path.join(output_path, "rope_cache.pt"))

        print("\nCompilation complete!")
        print(f"Model saved to: {output_path}")
        print(f"LoRA: {LORA_MODEL_ID} (merged into transformer weights)")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Compile transformer with LoRA merged (V3 CFG)")
    parser.add_argument("--height", type=int, default=1024)
    parser.add_argument("--width", type=int, default=512)
    parser.add_argument("--max_sequence_length", type=int, default=1024)
    parser.add_argument("--patch_multiplier", type=int, default=3)
    parser.add_argument("--tp_degree", type=int, default=16)
    parser.add_argument("--world_size", type=int, default=32)
    parser.add_argument("--compiled_models_dir", type=str, default="/opt/dlami/nvme/compiled_models_lora")
    parser.add_argument("--compiler_workdir", type=str, default="/opt/dlami/nvme/compiler_workdir_lora")
    args = parser.parse_args()

    compile_transformer_lora(args)
