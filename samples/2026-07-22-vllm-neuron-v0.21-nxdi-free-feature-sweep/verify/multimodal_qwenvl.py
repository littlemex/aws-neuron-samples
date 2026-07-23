#!/usr/bin/env python3
"""Verify multimodal (image + text) inference with a small Qwen3-VL.

Qwen3-VL 32B needs a larger box; the 4B variant fits on trn2.3xlarge. Launch:

  serve.sh ... -- --model Qwen/Qwen3-VL-4B-Instruct --tensor-parallel-size 4 \
     --max-model-len 8192 --max-num-batched-tokens 4096 --max-num-seqs 4 \
     --additional-config '{"neuron_config": {"num_batched_tokens_buckets": [4096], \
        "num_seqs_buckets": [4]}, "vision_neuron_config": {"num_vision_tokens_buckets": [2048], \
        "vision_attention_block_size": 2048}}'

Sends a solid-red image and asks for its color.
Usage: python3 multimodal_qwenvl.py [--base URL] [--model NAME]
Reference: docs/tutorials/tutorial-qwen3-vl-32b.md
"""
import argparse
import base64
import io

import requests
from PIL import Image


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8000")
    ap.add_argument("--model", default="Qwen/Qwen3-VL-4B-Instruct")
    args = ap.parse_args()

    img = Image.new("RGB", (64, 64), (220, 30, 30))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    b64 = base64.b64encode(buf.getvalue()).decode()

    r = requests.post(f"{args.base}/v1/chat/completions",
                      json={"model": args.model, "max_tokens": 15, "temperature": 0,
                            "messages": [{"role": "user", "content": [
                                {"type": "image_url", "image_url": {"url": f"data:image/png;base64,{b64}"}},
                                {"type": "text", "text": "What color is this image? Answer in one word."}]}]},
                      timeout=180)
    if r.status_code == 200:
        ans = r.json()["choices"][0]["message"]["content"]
        print("image+text ->", repr(ans))
        print("RESULT:", "PASS" if "red" in ans.lower() else "CHECK")
    else:
        print(f"HTTP {r.status_code}: {r.text[:200]}")
        print("RESULT: FAIL")


if __name__ == "__main__":
    main()
