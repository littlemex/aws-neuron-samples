#!/usr/bin/env python3
"""Flag isolation: are the vLLM Neuron plugin's own neuronx-cc compiler flags the
culprit, as opposed to the plugin's graph construction?

`version_isolation_trace.py` showed that `torch_neuronx.trace` with neuronx-cc's
DEFAULT flags compiles a truncated NemotronH-family hybrid faithfully. The plugin
invokes the SAME compiler version but with its OWN flags (constructed internally by
`vllm_neuron`'s model runner, not read from the `NEURON_CC_FLAGS` environment
variable -- see ../README.md, "Root-cause path" and
`docs/model-dev/onboarding-models.md` / `neuron_model_runner.py` in the plugin
source for how these are built). This script re-traces the SAME truncated model
with those exact flags to check whether the flags alone reproduce the on-device
failure.

- cos(device, cpu) ~= 1.0 with the plugin's flags => the flags are NOT the
  culprit; the plugin's own graph construction is.
- cos(device, cpu) << 1 => the flags ARE a contributing culprit; bisect which
  individual flag causes the divergence next.

In this investigation, the plugin's exact flag set applied to the same truncated
model scored cos=0.999896, identical to the default-flags control -- flags were
not the culprit.

Requires (on the real target environment, not for --dry-run):
    torch_neuronx, a NeuronCore, transformers==5.9.0, tokenizers==0.22.1.

Usage:
    python3 plugin_flags_trace.py --dry-run
    python3 plugin_flags_trace.py --model nvidia/Nemotron-H-8B-Base-8K
"""
import argparse
import sys
import time

DEFAULT_MODEL = "nvidia/Nemotron-H-8B-Base-8K"
DEFAULT_PROMPT = "Bob has 3 apples. Alice has twice as many apples as Bob. Alice has"

# The compiler flags the vLLM Neuron plugin constructs for its own model-runner
# compile, reproduced here verbatim (see the compile-invocation notes in
# verify/hlo_dump.md, "Command used to inspect the neuronx-cc invocation directly").
PLUGIN_COMPILER_ARGS = [
    "--auto-cast=none",
    "-O1",
    "--internal-hlo2tensorizer-options=--modular-flow-mac-threshold=10",
    "--internal-backend-options=--enable-verifier=false",
]


def parse_args():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--model", default=DEFAULT_MODEL)
    p.add_argument("--num-layers", type=int, default=16)
    p.add_argument("--seq-len", type=int, default=18)
    p.add_argument("--prompt", default=DEFAULT_PROMPT)
    p.add_argument("--dry-run", action="store_true")
    return p.parse_args()


def main():
    args = parse_args()

    if args.dry_run:
        print(f"[dry-run] would load {args.model!r}, truncate to the first "
              f"{args.num_layers} decoder layers, apply the seqscan Mamba2 patch, "
              f"trace with the plugin's own compiler_args={PLUGIN_COMPILER_ARGS}, "
              f"and compare device output against a CPU reference on the same "
              f"truncated model, reporting cos(device, cpu) and top-1 agreement.")
        try:
            import transformers  # noqa: F401
            from transformers.models.nemotron_h.modeling_nemotron_h import (  # noqa: F401
                NemotronHMamba2Mixer,
            )
        except Exception as e:
            print(f"[dry-run] NOTE: this environment cannot build the model "
                  f"({type(e).__name__}: {e}). Expected off-target -- requires "
                  f"transformers==5.9.0 and torch_neuronx on a Trainium host.")
        print("[dry-run] OK")
        return 0

    import torch
    import torch.nn.functional as F
    import torch_neuronx  # noqa: F401
    from transformers import AutoModelForCausalLM, AutoTokenizer
    from transformers.models.nemotron_h.modeling_nemotron_h import NemotronHMamba2Mixer
    from mamba2_seqscan import SeqScanMamba2Mixer

    NemotronHMamba2Mixer.torch_forward = SeqScanMamba2Mixer.torch_forward

    class Wrap(torch.nn.Module):
        def __init__(self, m):
            super().__init__()
            self.m = m

        def forward(self, ids):
            return self.m(input_ids=ids).logits

    tok = AutoTokenizer.from_pretrained(args.model)
    model = AutoModelForCausalLM.from_pretrained(
        args.model, dtype=torch.bfloat16, attn_implementation="eager", trust_remote_code=False
    ).eval()
    model.model.layers = model.model.layers[:args.num_layers]
    model.config.num_hidden_layers = args.num_layers
    w = Wrap(model).eval()

    ids = tok(args.prompt, return_tensors="pt").input_ids[:, :args.seq_len]
    with torch.no_grad():
        cpu = w(ids)[:, -1, :].float()
    print(f"[cpu] top1={tok.decode([cpu.argmax(-1).item()])!r}", flush=True)

    print(f"[trace] compiler_args={PLUGIN_COMPILER_ARGS} ...", flush=True)
    t0 = time.time()
    traced = torch_neuronx.trace(w, ids, compiler_args=PLUGIN_COMPILER_ARGS)
    with torch.no_grad():
        dev = traced(ids)[:, -1, :].float()

    cos = F.cosine_similarity(cpu.flatten(), dev.flatten(), dim=0).item()
    same_top1 = cpu.argmax(-1).item() == dev.argmax(-1).item()
    print(f"\n[RESULT] {time.time() - t0:.0f}s cos(device, cpu)={cos:.6f} "
          f"same_top1={same_top1} device_top1={tok.decode([dev.argmax(-1).item()])!r}")
    print("[verdict] cos ~1.0 => the plugin's own compiler flags are not the "
          "culprit; look at graph construction instead. cos << 1 => the flags "
          "are a contributing culprit.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
