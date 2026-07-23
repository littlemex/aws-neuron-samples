#!/usr/bin/env python3
"""Verify EAGLE3 speculative decoding and read the acceptance metrics.

Launch the server with an AWS-tested speculator (community EAGLE3 speculators
have an incompatible weight layout). Example for a GPT-OSS target:

  serve.sh ... -- --model openai/gpt-oss-20b --tensor-parallel-size 4 \
     --max-model-len 4096 --max-num-batched-tokens 2048 \
     --speculative-config '{"method": "eagle3", \
        "model": "RedHatAI/gpt-oss-20b-speculator.eagle3", "num_speculative_tokens": 5}' \
     --hf-overrides '{"quantization_config": {}}' \
     --additional-config '{"neuron_config": {"quantization": "bf16", \
        "on_device_sampling_config": {"temperature": "0"}, \
        "num_batched_tokens_buckets": [2048], "num_seqs_buckets": [4]}}'

Note: the last value of num_batched_tokens_buckets must equal max_num_batched_tokens.
Usage: python3 eagle3_metrics.py [--base URL] [--model NAME]
Reference: docs/guides/features-guide.md (Speculative decoding)
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
                            "max_tokens": 16, "temperature": 0}, timeout=120)
    print("completions ->", repr(r.json()["choices"][0]["text"]) if r.status_code == 200 else r.text[:200])

    m = requests.get(f"{args.base}/metrics").text
    print("--- spec-decode metrics ---")
    for line in m.splitlines():
        if any(k in line for k in ("spec_decode_num_drafts", "spec_decode_num_draft_tokens",
                                   "spec_decode_num_accepted_tokens")) and not line.startswith("#"):
            print(" ", line.strip())
    print("RESULT:", "PASS" if r.status_code == 200 else "FAIL")


if __name__ == "__main__":
    main()
