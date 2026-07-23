#!/usr/bin/env python3
"""Out-of-tree onboarding proof: run the plugin's SyntheticNeuronModel end to end.

The synthetic model implements the full runner<->model contract (from_configs,
get_kv_spec, bind_kv_cache, forward on prefill+decode, load_weights) without
real weights or NEFF compilation. LLM.generate() returning tokens proves the
onboarding contract. Runs in CPU mode, so no NeuronCore is required.

Run with:
    VLLM_NEURON_CPU_MODE=1 VLLM_NEURON_SYNTHETIC_MODEL=1 python3 oot_synthetic_e2e.py

Reference: docs/model-dev/onboarding-models.md, vllm_neuron/model/synthetic/
"""
import os

os.environ.setdefault("VLLM_NEURON_CPU_MODE", "1")
os.environ.setdefault("VLLM_NEURON_SYNTHETIC_MODEL", "1")
os.environ.setdefault("VLLM_ENABLE_V1_MULTIPROCESSING", "0")

import vllm_neuron.model.synthetic as _syn

CFG = os.path.join(os.path.dirname(_syn.__file__), "synthetic_config")


def main() -> int:
    from vllm_neuron.model.registry import get_models
    names = [n for n, _ in get_models()]
    print("registry has SyntheticNeuronModel:", "SyntheticNeuronModel" in names)

    from vllm import LLM, SamplingParams
    llm = LLM(model=CFG, tensor_parallel_size=1, max_model_len=512,
              max_num_seqs=1, enforce_eager=True, trust_remote_code=True,
              enable_prefix_caching=False)  # synthetic infra test; APC not needed
    out = llm.generate(["Hello world, this is an onboarding contract test."],
                       SamplingParams(max_tokens=8, temperature=0))
    ntok = len(out[0].outputs[0].token_ids)
    print(f"generate() returned {ntok} tokens")
    print("RESULT:", "PASS" if ntok > 0 else "FAIL")
    return 0 if ntok > 0 else 1


if __name__ == "__main__":
    raise SystemExit(main())
