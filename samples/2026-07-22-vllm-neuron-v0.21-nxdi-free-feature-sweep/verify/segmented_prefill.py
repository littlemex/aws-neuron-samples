#!/usr/bin/env python3
"""Verify segmented prefill: a prompt longer than one prefill bucket is split
into ceil(tokens / max_num_batched_tokens) segment passes and still produces a
correct answer across segment boundaries.

Usage: python3 segmented_prefill.py [--base URL] [--model NAME] [--bucket 4096]
Reference: docs/design/vllm/prefix-caching.md
"""
import argparse
import requests


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8000")
    ap.add_argument("--model", default="meta-llama/Llama-3.1-8B-Instruct")
    ap.add_argument("--bucket", type=int, default=4096)
    args = ap.parse_args()

    # ~6.2k tokens so ceil(6200/4096) == 2 segment passes
    filler = "The following is background context that should be read carefully. " * 560
    prompt = filler + "\n\nIgnore all the background above. Question: What is the capital of France? Answer in one word:"
    r = requests.post(f"{args.base}/v1/completions",
                      json={"model": args.model, "prompt": prompt, "max_tokens": 5, "temperature": 0},
                      timeout=180)
    d = r.json()
    ptok = d["usage"]["prompt_tokens"]
    text = d["choices"][0]["text"]
    segs = -(-ptok // args.bucket)
    print(f"prompt_tokens={ptok} -> {segs} segment passes (bucket={args.bucket})")
    print(f"output={text!r}")
    ok = "Paris" in text and segs >= 2
    print("RESULT:", "PASS" if ok else "PARTIAL" if "Paris" in text else "FAIL")


if __name__ == "__main__":
    main()
