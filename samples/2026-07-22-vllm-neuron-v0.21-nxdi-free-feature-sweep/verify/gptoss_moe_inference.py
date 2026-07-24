#!/usr/bin/env python3
"""Verify GPT-OSS 20B (MoE) runs in BF16 on Trn2.

GPT-OSS ships as an MXFP4 checkpoint; MXFP4 execution is Trn3-only. On Trn2 the
model runs in BF16 once the HF-config quantization declaration is cleared and
neuron_config.quantization=bf16 is requested. Launch the server with:

  serve.sh ... -- --model openai/gpt-oss-20b --tensor-parallel-size 4 \
     --hf-overrides '{"quantization_config": {}}' \
     --additional-config '{"neuron_config": {"quantization": "bf16", \
        "num_batched_tokens_buckets": [4096], "num_seqs_buckets": [4]}}'

Usage: python3 gptoss_moe_inference.py [--base URL]
Reference: docs/model-recipes/gpt-oss.md, docs/tutorials/tutorial-gpt-oss.md
"""
import argparse
import requests


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8000")
    ap.add_argument("--model", default="openai/gpt-oss-20b")
    args = ap.parse_args()

    r = requests.post(f"{args.base}/v1/completions",
                      json={"model": args.model, "prompt": "The capital of France is",
                            "max_tokens": 8, "temperature": 0}, timeout=120)
    print("completions ->", repr(r.json()["choices"][0]["text"]) if r.status_code == 200 else r.text[:200])

    # GPT-OSS interleaves harmony-style reasoning before the final answer, so it
    # needs enough tokens to reach it; 512 is comfortable. The final answer lands
    # in message.content, but some builds surface it in reasoning_content, so we
    # check both and guard against either being None.
    r2 = requests.post(f"{args.base}/v1/chat/completions",
                       json={"model": args.model,
                             "messages": [{"role": "user", "content": "What is 17 times 23?"}],
                             "max_tokens": 512, "temperature": 0}, timeout=180)
    msg = r2.json()["choices"][0]["message"] if r2.status_code == 200 else {}
    ans = " ".join(str(msg.get(k) or "") for k in ("content", "reasoning_content"))
    print("chat ->", repr(ans)[:150])
    print("RESULT:", "PASS" if (r.status_code == 200 and "391" in ans) else "CHECK")


if __name__ == "__main__":
    main()
