"""
Download and cache the Lightning distilled LoRA and base model.

Lightning LoRA: lightx2v/Qwen-Image-Edit-2511-Lightning
Base: Qwen/Qwen-Image-Edit-2511
Key feature: 4-step inference (vs 40 steps for base model)
"""

import torch
from diffusers import QwenImageEditPlusPipeline
from huggingface_hub import hf_hub_download

BASE_MODEL_ID = "Qwen/Qwen-Image-Edit-2511"
LIGHTNING_MODEL_ID = "lightx2v/Qwen-Image-Edit-2511-Lightning"
LIGHTNING_FILENAME = "Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors"
CACHE_DIR = "/opt/dlami/nvme/qwen_image_edit_hf_cache_dir"
LIGHTNING_CACHE_DIR = "/opt/dlami/nvme/lightning_cache"

if __name__ == "__main__":
    # Download base model
    print(f"Downloading base model {BASE_MODEL_ID} to {CACHE_DIR}...")
    pipe = QwenImageEditPlusPipeline.from_pretrained(
        BASE_MODEL_ID,
        torch_dtype=torch.bfloat16,
        cache_dir=CACHE_DIR
    )
    del pipe
    print("Base model downloaded successfully!")

    # Download Lightning LoRA weights
    print(f"\nDownloading Lightning LoRA {LIGHTNING_MODEL_ID}...")
    lora_path = hf_hub_download(
        repo_id=LIGHTNING_MODEL_ID,
        filename=LIGHTNING_FILENAME,
        cache_dir=LIGHTNING_CACHE_DIR
    )
    print(f"Lightning LoRA downloaded to: {lora_path}")
    print("All models downloaded successfully!")
