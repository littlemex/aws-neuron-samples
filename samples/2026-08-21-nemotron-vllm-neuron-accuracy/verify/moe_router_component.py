#!/usr/bin/env python3
"""Component isolation: does the plugin's MoE router (`dense_moe_gate` in ops.py)
mis-select experts when compiled on neuronx-cc?

`dense_moe_gate` is a DGE-free (no data-dependent gather/scatter) top-k router
reformulation -- see ops.py's own docstring for why the plugin avoids a plain
scatter-based top-k on Neuron. Router top-k selection is inherently discrete: even
a tiny per-element compile error can flip which experts are chosen for a token,
which is a qualitatively different (and much more damaging) failure mode than
ordinary BF16 rounding of continuous values. This is MoE-specific, which lines up
with an observation from this investigation: an 8B dense (no-MoE) truncation of
the model traced faithfully, while the full 30B (MoE-containing) model failed
on-device.

This script compares the actual expert SELECTION MASK (which experts were chosen
per token), not just a cosine similarity of the gate output, because a router bug
that flips a small number of selections can hide behind an otherwise-high cosine
over a [tokens, experts] tensor that is mostly zero. It runs two configurations:

    single    -- one router layer in isolation.
    stackedN  -- N router layers chained with a cheap synthetic coupling (each
                 layer's output nudges the next layer's input scores), as a proxy
                 for what changes when many MoE layers are stacked in the real
                 52-layer hybrid. This is a SYNTHETIC stand-in for the real
                 30B model's stacked routing, not a measurement of the real
                 model's actual per-layer numbers -- see the caveat in
                 ../README.md, "Root-cause path".

In this investigation: `single` scored 0 tokens with a different expert selection
out of 256 (faithful). `stacked23` (mimicking the 23 stacked MoE layers in the real
model) scored 8/256 tokens with a different selection -- demonstrating that tiny
per-layer differences CAN compound across many stacked router layers into an
actual expert-selection flip, even though no single router layer is at fault in
isolation.

Requires (on the real target environment, not for --dry-run):
    torch_neuronx, a NeuronCore.

Usage:
    python3 moe_router_component.py --dry-run
    python3 moe_router_component.py --num-experts 128 --top-k 6 --stack-depth 23
"""
import argparse
import sys
import time

import torch
import torch.nn.functional as F

from ops import dense_moe_gate

NUM_TOKENS = 256


class SingleGate(torch.nn.Module):
    def __init__(self, top_k):
        super().__init__()
        self.top_k = top_k

    def forward(self, scores, bias):
        return dense_moe_gate(scores, bias, self.top_k, True, 1.0)


class StackedGate(torch.nn.Module):
    """Chains `depth` router calls with a cheap synthetic coupling between them,
    as a stand-in for stacked MoE layers (see module docstring caveat)."""

    def __init__(self, depth, top_k):
        super().__init__()
        self.depth = depth
        self.top_k = top_k

    def forward(self, scores, bias):
        s = scores
        acc = torch.zeros_like(scores)
        for _ in range(self.depth):
            g = dense_moe_gate(s, bias, self.top_k, True, 1.0)
            acc = acc + g
            s = torch.sigmoid(s + 0.01 * g.sum(-1, keepdim=True))
        return acc


def make_inputs(num_tokens, num_experts, seed, dtype=torch.bfloat16):
    g = torch.Generator().manual_seed(seed)
    scores = torch.sigmoid(torch.randn(num_tokens, num_experts, generator=g)).to(dtype)
    bias = (0.1 * torch.randn(num_experts, generator=g)).to(dtype)
    return scores, bias


def selection_mask(gate):
    return (gate.float().abs() > 0).int()   # [tokens, experts], 1 where an expert was chosen


def compare(cpu, dev):
    sel_cpu, sel_dev = selection_mask(cpu), selection_mask(dev)
    mismatched_tokens = (sel_cpu != sel_dev).any(dim=-1).sum().item()
    cos = F.cosine_similarity(cpu.flatten().float(), dev.flatten().float(), dim=0).item()
    return cos, mismatched_tokens


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--num-experts", type=int, default=128)
    ap.add_argument("--top-k", type=int, default=6)
    ap.add_argument("--stack-depth", type=int, default=23,
                     help="number of router layers in the synthetic stacked variant "
                          "(23 = the number of MoE layers in the real 52-layer hybrid)")
    ap.add_argument("--dry-run", action="store_true",
                     help="run the CPU-only router forward (real signal, no Neuron "
                          "dependency) but skip torch_neuronx.trace and the device")
    args = ap.parse_args()

    configs = [
        ("single", SingleGate(args.top_k)),
        (f"stacked{args.stack_depth}", StackedGate(args.stack_depth, args.top_k)),
    ]

    if args.dry_run:
        for tag, mod in configs:
            scores, bias = make_inputs(NUM_TOKENS, args.num_experts, seed=0)
            with torch.no_grad():
                out = mod(scores, bias)
            print(f"[dry-run] {tag}: output_shape={list(out.shape)} "
                  f"nonzero_selections={int((out.float().abs() > 0).sum().item())}")
        print("[dry-run] OK: CPU-only router forward ran for all configs; "
              "torch_neuronx.trace and the on-device run were skipped")
        return 0

    import torch_neuronx  # noqa: F401

    for tag, mod in configs:
        scores, bias = make_inputs(NUM_TOKENS, args.num_experts, seed=0)
        with torch.no_grad():
            cpu = mod(scores, bias)
        t0 = time.time()
        traced = torch_neuronx.trace(mod, (scores, bias))
        with torch.no_grad():
            dev = traced(scores, bias)
        print(f"\n=== {tag} ({time.time() - t0:.0f}s) ===", flush=True)
        cos, mismatched = compare(cpu, dev)
        print(f"[{tag}] cos={cos:.6f} tokens_with_different_selection={mismatched}/{NUM_TOKENS}")

    print("\n[verdict] tokens_with_different_selection > 0 => the router mis-selects "
          "experts on device at that stack depth => a candidate culprit. 0 at every "
          "depth tested => router selection is faithful at those depths.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
