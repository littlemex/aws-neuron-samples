"""
Download and cache the LoRA model and base model for virtual try-on.

LoRA: JamesDigitalOcean/Qwen_Image_Edit_Try_On_Clothes
Base: Qwen/Qwen-Image-Edit-2509
Trigger word: "tryon_clothes"
"""

import torch
from diffusers import QwenImageEditPlusPipeline
from huggingface_hub import hf_hub_download

BASE_MODEL_ID = "Qwen/Qwen-Image-Edit-2509"
LORA_MODEL_ID = "JamesDigitalOcean/Qwen_Image_Edit_Try_On_Clothes"
LORA_FILENAME = "qwen_image_edit_tryon.safetensors"
CACHE_DIR = "/opt/dlami/nvme/qwen_image_edit_hf_cache_dir"
LORA_CACHE_DIR = "/opt/dlami/nvme/lora_cache"

if __name__ == "__main__":
    # Download base model
    print(f"Downloading base model {BASE_MODEL_ID} to {CACHE_DIR}...")
    pipe = QwenImageEditPlusPipeline.from_pretrained(
        BASE_MODEL_ID,
        torch_dtype=torch.bfloat16,
        cache_dir=CACHE_DIR
    )
    print("Base model downloaded successfully!")

    # Download LoRA weights
    print(f"\nDownloading LoRA {LORA_MODEL_ID}...")
    lora_path = hf_hub_download(
        repo_id=LORA_MODEL_ID,
        filename=LORA_FILENAME,
        cache_dir=LORA_CACHE_DIR
    )
    print(f"LoRA downloaded to: {lora_path}")
    print("All models downloaded successfully!")
