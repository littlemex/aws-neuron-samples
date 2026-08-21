#!/usr/bin/env python3
"""Component isolation: does the plugin's Mamba2 prefill kernel (`chunked_ssd_scan`
in ssd.py) itself mis-compile on neuronx-cc, independent of the rest of the model?

`chunked_ssd_scan` is self-contained (pure PyTorch, no plugin/Neuron dependency --
see ssd.py's own docstring), which makes it cheap to trace and check in isolation,
without building a full NemotronH model. This script traces it standalone at the
plugin's real Mamba2 dimensions and compares against a CPU reference using a
three-way BF16-noise-floor ratio, not a raw cosine similarity, because a raw
cosine at large random-input magnitudes over-states the divergence (BF16 rounding
alone can push cosine down at those magnitudes even when the device is faithful).

Three-way comparison (see ../README.md, "Debug method: three-way noise-floor
comparison"):
    err(BF16, FP32)    = || bf16-CPU output - fp32-CPU output ||  (inherent BF16 noise)
    err(device, FP32)  = || bf16-device output - fp32-CPU output ||
    ratio = err(device, FP32) / err(BF16, FP32)

- ratio ~= 1 (or below) => the device error is no larger than ordinary BF16
  rounding; the kernel compiles faithfully. NOT the culprit.
- ratio >> 1 => the device introduces error beyond BF16 rounding; the kernel's
  compilation IS a candidate culprit.

In this investigation, `chunked_ssd_scan` at l=256 (two chunks) and l=384 (three
chunks) scored ratio=0.82 and 0.75 respectively -- device error was AT OR BELOW
the BF16 noise floor. Faithful; not the culprit.

Note: sequence lengths shorter than `chunk_size` were observed to fail to compile
at all with an internal neuronx-cc error (NCC_IMPR902, a MaskPropagation /
isl_set_union failure), a known degenerate-chunk-count issue distinct from a
numerical accuracy question. Use `--seq-len` values >= `--chunk-size` to avoid it;
this script's defaults already do.

Requires (on the real target environment, not for --dry-run):
    torch_neuronx, a NeuronCore.

Usage:
    python3 chunked_ssd_component.py --dry-run
    python3 chunked_ssd_component.py --seq-lens 256,384
"""
import argparse
import sys
import time

import torch
import torch.nn.functional as F

from ssd import chunked_ssd_scan

# Mamba2 dimensions matching the 30B-class NemotronH checkpoint used in this
# investigation (mamba_num_heads, mamba_head_dim, ssm_state_size, and the chunk
# size the plugin's chunked_ssd_scan uses internally).
H, P, N, CHUNK_SIZE = 64, 64, 128, 128
DTYPE = torch.bfloat16


class Wrap(torch.nn.Module):
    def __init__(self, chunk_size):
        super().__init__()
        self.chunk_size = chunk_size

    def forward(self, x, B, C, dt, A, D):
        y, _h = chunked_ssd_scan(x, B, C, dt, A, D, self.chunk_size)
        return y


def make_inputs(seq_len, seed, dtype):
    g = torch.Generator().manual_seed(seed)
    # Scale down from unit-variance random noise: this keeps the scan's
    # magnitude in the range real activations occupy, avoiding a BF16-noise
    # artifact where large-magnitude random inputs make plain cosine look
    # worse than the kernel's real fidelity.
    x = (0.2 * torch.randn(1, seq_len, H, P, generator=g)).to(dtype)
    B = (0.2 * torch.randn(1, seq_len, H, N, generator=g)).to(dtype)
    C = (0.2 * torch.randn(1, seq_len, H, N, generator=g)).to(dtype)
    dt = (0.1 * F.softplus(torch.randn(1, seq_len, H, generator=g))).to(dtype)  # >= 0
    A = (-torch.exp(torch.randn(H, generator=g))).to(dtype)                    # <= 0
    D = torch.randn(H, generator=g).to(dtype)
    return x, B, C, dt, A, D


def rel_err(a, ref):
    return (a.float() - ref.float()).norm().item() / (ref.float().norm().item() + 1e-9)


def cos_sim(a, b):
    return F.cosine_similarity(a.flatten().float(), b.flatten().float(), dim=0).item()


def run_cpu_only(seq_len, chunk_size):
    """Builds fp32/bf16 inputs and runs the CPU-only forward for one seq_len.
    Returns (module, args_bf16, cpu_bf16, cpu_fp32) for reuse by the on-device path.
    """
    w = Wrap(chunk_size).eval()
    args_fp32 = make_inputs(seq_len, seed=seq_len, dtype=torch.float32)
    args_bf16 = tuple(a.to(torch.bfloat16) for a in args_fp32)
    with torch.no_grad():
        cpu_fp32 = w(*args_fp32)
        cpu_bf16 = w(*args_bf16)
    return w, args_bf16, cpu_bf16, cpu_fp32


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--seq-lens", default="256,384",
                     help="comma-separated sequence lengths to test; each must be "
                          ">= --chunk-size to avoid the NCC_IMPR902 degenerate case")
    ap.add_argument("--chunk-size", type=int, default=CHUNK_SIZE)
    ap.add_argument("--dry-run", action="store_true",
                     help="run the CPU-only computation (real signal, no Neuron "
                          "dependency) but skip torch_neuronx.trace and the device")
    args = ap.parse_args()
    seq_lens = [int(x) for x in args.seq_lens.split(",")]

    if args.dry_run:
        for l in seq_lens:
            w, args_bf16, cpu_bf16, cpu_fp32 = run_cpu_only(l, args.chunk_size)
            noise_floor = rel_err(cpu_bf16, cpu_fp32)
            print(f"[dry-run] seq_len={l} chunks={-(-l // args.chunk_size)} "
                  f"output_shape={list(cpu_bf16.shape)} "
                  f"bf16_noise_floor(rel_err vs fp32)={noise_floor:.4e}")
        print("[dry-run] OK: CPU-only forward passes ran for all seq_lens; "
              "torch_neuronx.trace and the on-device run were skipped")
        return 0

    import torch_neuronx  # noqa: F401  (only needed for the real device run)

    for l in seq_lens:
        print(f"\n=== chunked_ssd_scan seq_len={l} (chunks={-(-l // args.chunk_size)}) ===",
              flush=True)
        w, args_bf16, cpu_bf16, cpu_fp32 = run_cpu_only(l, args.chunk_size)
        t0 = time.time()
        traced = torch_neuronx.trace(w, args_bf16)
        with torch.no_grad():
            dev_bf16 = traced(*args_bf16)
        err_bf16 = rel_err(cpu_bf16, cpu_fp32)
        err_dev = rel_err(dev_bf16, cpu_fp32)
        ratio = err_dev / (err_bf16 + 1e-12)
        print(f"[RESULT seq_len={l}] {time.time() - t0:.0f}s "
              f"cos(device, cpu_bf16)={cos_sim(dev_bf16, cpu_bf16):.6f} "
              f"rel_err(bf16_cpu, fp32)={err_bf16:.4e} "
              f"rel_err(device, fp32)={err_dev:.4e} ratio={ratio:.2f}")

    print("\n[verdict] ratio ~1 (or below) at every seq_len => the kernel compiles "
          "faithfully; not the culprit. ratio >> 1 => the kernel's compilation is "
          "a candidate culprit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
