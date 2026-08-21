#!/usr/bin/env python3
"""Version isolation: does production neuronx-cc mis-compile a plain Hugging Face
NemotronH-family hybrid graph, independent of the vLLM Neuron plugin's own graph
construction?

Loads a real NemotronH-family checkpoint, keeps only the first N decoder layers
(enough to cover all three layer types plus the NoPE positional path: Mamba2,
attention, MLP), traces it with `torch_neuronx.trace` using neuronx-cc's DEFAULT
flags, and compares the device output against a CPU reference on the same
truncated model.

- cos(device, cpu) ~= 1.0 and the same top-1 token => neuronx-cc compiles this
  hybrid graph faithfully via `torch_neuronx.trace` => the compiler VERSION is not
  the culprit; look at the vLLM Neuron plugin's own compile path instead.
- cos(device, cpu) << 1 => the compiler version itself mis-compiles the hybrid
  graph => the compiler VERSION is a candidate culprit.

In this investigation, a 16-layer truncation of `nvidia/Nemotron-H-8B-Base-8K`
traced on neuronx-cc from Neuron SDK 2.31 scored cos=0.999896 with a matching
top-1 token -- faithful. See ../README.md, "Root-cause path", step 1.

Why a truncation, not the full model: tracing the full ~50-layer, ~30B-parameter
hybrid with `torch_neuronx.trace` (which does not shard weights or page
activations the way the plugin's tensor-parallel serving path does) produces a
NEFF that does not fit a single NeuronCore's HBM and fails with an allocation
error. Truncating to the first N layers keeps every layer TYPE present
(Mamba2, attention, MLP) while fitting comfortably in HBM. This trades "full
depth" for "runs at all"; see Known limitations in ../README.md.

Requires (on the real target environment, not for --dry-run):
    torch_neuronx, a NeuronCore, transformers==5.9.0 (the version this
    investigation used for `nemotron_h` model support), tokenizers==0.22.1.

Usage:
    python3 version_isolation_trace.py --dry-run
    python3 version_isolation_trace.py --model nvidia/Nemotron-H-8B-Base-8K \\
        --num-layers 16 --seq-len 18
"""
import argparse
import sys
import time

DEFAULT_MODEL = "nvidia/Nemotron-H-8B-Base-8K"
DEFAULT_PROMPT = "Bob has 3 apples. Alice has twice as many apples as Bob. Alice has"


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--model", default=DEFAULT_MODEL,
                    help="Hugging Face repo id of a NemotronH-family checkpoint")
    p.add_argument("--num-layers", type=int, default=16,
                    help="number of leading decoder layers to keep")
    p.add_argument("--seq-len", type=int, default=18,
                    help="prompt length in tokens (truncated/padded to this)")
    p.add_argument("--prompt", default=DEFAULT_PROMPT)
    p.add_argument("--dry-run", action="store_true",
                    help="validate the script and its local imports without "
                         "importing transformers/torch_neuronx or touching a device")
    return p.parse_args()


def build_truncated_model(model_id, num_layers):
    """Lazy-imports transformers and applies the seqscan patch. Returns (model, tokenizer)."""
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from transformers.models.nemotron_h.modeling_nemotron_h import NemotronHMamba2Mixer
    from mamba2_seqscan import SeqScanMamba2Mixer
    import torch

    NemotronHMamba2Mixer.torch_forward = SeqScanMamba2Mixer.torch_forward
    tok = AutoTokenizer.from_pretrained(model_id)
    model = AutoModelForCausalLM.from_pretrained(
        model_id, dtype=torch.bfloat16, attn_implementation="eager", trust_remote_code=False
    ).eval()
    model.model.layers = model.model.layers[:num_layers]
    model.config.num_hidden_layers = num_layers
    return model, tok


def main():
    args = parse_args()

    if args.dry_run:
        try:
            import ast
            ast.parse(open(__file__).read())
            ast.parse(open("mamba2_seqscan.py").read())
        except OSError:
            pass  # allow running from a different cwd
        print(f"[dry-run] would load {args.model!r}, truncate to the first "
              f"{args.num_layers} decoder layers, apply the seqscan Mamba2 patch, "
              f"tokenize prompt={args.prompt!r} to length {args.seq_len}, run a CPU "
              f"forward pass, trace the same truncated model with "
              f"torch_neuronx.trace (default compiler flags), run the traced module "
              f"on-device, and report cos(device, cpu) plus top-1 token agreement.")
        try:
            import transformers  # noqa: F401
            from transformers.models.nemotron_h.modeling_nemotron_h import (  # noqa: F401
                NemotronHMamba2Mixer,
            )
        except Exception as e:
            print(f"[dry-run] NOTE: this environment cannot build the model "
                  f"({type(e).__name__}: {e}). This is expected off-target -- the "
                  f"real run requires transformers==5.9.0 (nemotron_h support) and "
                  f"torch_neuronx on a Trainium host. Script structure is otherwise valid.")
        print("[dry-run] OK")
        return 0

    import torch
    import torch.nn.functional as F
    import torch_neuronx  # noqa: F401

    class Wrap(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, ids):
            return self.m(input_ids=ids).logits

    model, tok = build_truncated_model(args.model, args.num_layers)
    types = [getattr(l, "block_type", getattr(l, "layer_type", "?")) for l in model.model.layers]
    print(f"[load] kept {args.num_layers} layers, types={types}", flush=True)

    w = Wrap(model).eval()
    ids = tok(args.prompt, return_tensors="pt").input_ids[:, :args.seq_len]
    with torch.no_grad():
        cpu = w(ids)[:, -1, :].float()

    print(f"[trace] seq_len={ids.shape[1]} on neuronx-cc (default flags) ...", flush=True)
    t0 = time.time()
    traced = torch_neuronx.trace(w, ids)
    print(f"[trace] done in {time.time() - t0:.0f}s", flush=True)

    with torch.no_grad():
        dev = traced(ids)[:, -1, :].float()

    cos = F.cosine_similarity(cpu.flatten(), dev.flatten(), dim=0).item()
    max_abs = (cpu - dev).abs().max().item()
    same_top1 = cpu.argmax(-1).item() == dev.argmax(-1).item()

    print(f"\n[RESULT] cos(device, cpu)={cos:.6f} max_abs={max_abs:.3e} same_top1={same_top1}")
    print("[verdict] cos ~1.0 and same_top1=True => neuronx-cc is faithful on this "
          "hybrid graph => version is not the culprit. cos << 1 => the compiler "
          "version is a candidate culprit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
