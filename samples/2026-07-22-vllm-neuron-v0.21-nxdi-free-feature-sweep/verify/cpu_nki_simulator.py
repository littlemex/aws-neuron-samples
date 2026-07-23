#!/usr/bin/env python3
"""Verify CPU mode and the NKI CPU simulator without any NeuronCore.

Runs two real NKI kernels through the NumPy-backed simulator and checks that
the output matches a NumPy reference, then exercises the plugin's own
simulate_nki_kernel wrapper (torch<->numpy path).

Run with:
    VLLM_NEURON_CPU_MODE=1 NKI_SIMULATOR=1 python3 cpu_nki_simulator.py

Reference: docs/model-dev/nki_cpu_simulator.md
"""
import os

os.environ.setdefault("VLLM_NEURON_CPU_MODE", "1")
os.environ.setdefault("NKI_SIMULATOR", "1")

import numpy as np
import torch
import nki
import nki.language as nl
from nki.simulator import simulate_kernel


@nki.jit
def add_kernel(a_tensor, b_tensor):
    out = nl.ndarray(a_tensor.shape, dtype=a_tensor.dtype, buffer=nl.shared_hbm)
    a = nl.load(a_tensor)
    b = nl.load(b_tensor)
    nl.store(out, nl.add(a, b))
    return out


@nki.jit
def mul_exp_kernel(a_tensor, b_tensor):
    out = nl.ndarray(a_tensor.shape, dtype=a_tensor.dtype, buffer=nl.shared_hbm)
    a = nl.load(a_tensor)
    b = nl.load(b_tensor)
    nl.store(out, nl.exp(nl.multiply(a, b)))
    return out


def main() -> int:
    print(f"NKI version: {nki.__version__}")
    a = np.random.randn(128, 512).astype(np.float32)
    b = np.random.randn(128, 512).astype(np.float32)

    ok = True

    o1 = simulate_kernel(add_kernel, (), {"a_tensor": a, "b_tensor": b}, lnc=1)
    e1 = float(np.abs(o1 - (a + b)).max())
    print(f"[add]      sim-vs-ref max abs err = {e1:.2e}  -> {'PASS' if e1 < 1e-4 else 'FAIL'}")
    ok &= e1 < 1e-4

    o2 = simulate_kernel(mul_exp_kernel, (), {"a_tensor": a, "b_tensor": b}, lnc=1)
    e2 = float(np.abs(o2 - np.exp(a * b)).max())
    print(f"[exp*mul]  sim-vs-ref max abs err = {e2:.2e}  -> {'PASS' if e2 < 1e-2 else 'FAIL'}")
    ok &= e2 < 1e-2

    from vllm_neuron.nki.nki_cpu_sim import simulate_nki_kernel

    r = simulate_nki_kernel(
        add_kernel, 1, {"a_tensor": torch.from_numpy(a), "b_tensor": torch.from_numpy(b)}
    )
    e3 = float((r - torch.from_numpy(a + b)).abs().max().item())
    print(f"[wrapper]  torch<->numpy max abs err = {e3:.2e}  -> {'PASS' if e3 < 1e-4 else 'FAIL'}")
    ok &= e3 < 1e-4

    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    raise SystemExit(main())
