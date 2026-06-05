import os

import torch
from diffusers import QwenImageEditPlusPipeline

# Cache location precedence: explicit HF_CACHE_DIR -> standard HF_HOME ->
# the DLAMI NVMe convention. The DLAMI path remains the ultimate fallback
# so existing operators do not have to change anything; non-DLAMI hosts
# just set HF_HOME (or HF_CACHE_DIR) to a writable directory.
CACHE_DIR = os.environ.get(
    "HF_CACHE_DIR",
    os.environ.get("HF_HOME", "/opt/dlami/nvme/qwen_image_edit_hf_cache_dir"),
)
MODEL_ID = "Qwen/Qwen-Image-Edit-2511"

if __name__ == "__main__":
    print(f"Downloading {MODEL_ID} to {CACHE_DIR}...")
    pipe = QwenImageEditPlusPipeline.from_pretrained(
        MODEL_ID,
        torch_dtype=torch.bfloat16,
        cache_dir=CACHE_DIR
    )
    print("Model downloaded successfully!")
