#!/usr/bin/env python3
"""Measure the prefix-caching TTFT benefit against a running server.

Key finding: on Neuron the benefit is quantized to segment/bucket boundaries.
A prompt that fits in a single prefill bucket shows no TTFT change even on a
cache hit; a prompt that spans multiple segments does. This script drives a
long shared prefix so the effect is visible.

Usage: python3 prefix_cache_ttft.py [--base URL] [--model NAME]

Reference: docs/design/vllm/prefix-caching.md, docs/guides/features-guide.md
"""
import argparse
import statistics
import time

import requests


def toklen(base, model, prompt):
    r = requests.post(f"{base}/v1/completions",
                      json={"model": model, "prompt": prompt, "max_tokens": 1, "temperature": 0},
                      timeout=120)
    return r.json()["usage"]["prompt_tokens"]


def ttft(base, model, prompt, n=8):
    lat = []
    for _ in range(n):
        t0 = time.time()
        requests.post(f"{base}/v1/completions",
                      json={"model": model, "prompt": prompt, "max_tokens": 1, "temperature": 0},
                      timeout=120)
        lat.append(time.time() - t0)
    return statistics.median(lat)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--base", default="http://localhost:8000")
    ap.add_argument("--model", default="meta-llama/Llama-3.1-8B-Instruct")
    args = ap.parse_args()

    unit = ("The system operates under the following detailed policy guidelines "
            "and constraints that must be strictly followed at all times. ")
    # Must exceed one prefill bucket (4096) so a cache hit removes a whole segment
    # pass. On Neuron the TTFT benefit is quantized to segment/bucket boundaries:
    # a prompt that fits in a single bucket shows no TTFT change even on a hit.
    shared = unit * 240  # ~5k tokens -> 2 segment passes at the 4096 bucket
    n = toklen(args.base, args.model, shared + "prime")
    print(f"shared-prefix tokens: {n}")

    # prime the shared prefix so it is cached
    requests.post(f"{args.base}/v1/completions",
                  json={"model": args.model, "prompt": shared + "prime", "max_tokens": 1, "temperature": 0},
                  timeout=120)

    warm = ttft(args.base, args.model, shared + "Q")  # shared prefix cached
    cold_prompts_ttft = []
    for i in range(8):
        uniq = (f"Distinct preamble variant {i} " + unit) * 60
        t0 = time.time()
        requests.post(f"{args.base}/v1/completions",
                      json={"model": args.model, "prompt": uniq[:len(shared)] + "Q",
                            "max_tokens": 1, "temperature": 0}, timeout=120)
        cold_prompts_ttft.append(time.time() - t0)
    cold = statistics.median(cold_prompts_ttft)

    print(f"WARM (shared prefix cached): TTFT median = {warm:.3f}s")
    print(f"COLD (unique prefix each):   TTFT median = {cold:.3f}s")
    print(f"speedup (cold/warm): {cold / warm:.2f}x")
    # The functional proof of prefix caching is the hit counter below. The TTFT
    # speedup is quantized to segment/bucket boundaries and is sensitive to how
    # many segment passes the warm remainder still needs, so it can read ~1.0x
    # unless the cache hit removes a whole prefill pass. The metric always moves.
    m = requests.get(f"{args.base}/metrics").text
    for line in m.splitlines():
        if ("prefix_cache_hits_total" in line or "prompt_tokens_cached_total" in line) and not line.startswith("#"):
            print(" ", line.strip())


if __name__ == "__main__":
    main()
