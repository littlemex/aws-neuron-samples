# Verify scripts

Each script isolates one candidate cause for the on-device reasoning
regression described in `../README.md`. Run `dry_run_all.sh` first (no
NeuronCore, no checkpoint, no serving endpoint needed) to confirm your
checkout is intact before spending compile time on real hardware.

**None of the scripts below has produced a valid elimination.** Each one
exercises a single forward pass through some sub-graph of the model; see
`../README.md`'s "Why this is not a valid elimination chain" for the
variable-matrix reason none of them, individually or together, has isolated
a root cause. The recommended next step, `per_step_logit_diff.md`, is a
*procedure*, not a script — it is described but not yet executed in this
investigation.

| Script | Isolates | Needs | Verdict rule |
|---|---|---|---|
| `probes.py` | Whether a served endpoint answers 12 reasoning prompts correctly | A running `/v1/completions` endpoint (Trainium or GPU) | pass/fail per prompt, see `../README.md` for the observed pattern |
| `version_isolation_trace.py` | Whether the neuronx-cc **compiler version** itself mis-compiles a plain hybrid graph, via `torch_neuronx.trace` with default flags | `torch_neuronx`, a NeuronCore, `transformers==5.9.0` | cos(device, cpu) ~1.0 => version innocent |
| `plugin_flags_trace.py` | Whether the plugin's **own compiler flags** (not the version) are the culprit | same as above | cos ~1.0 with plugin flags => flags innocent |
| `chunked_ssd_component.py` | Whether the Mamba2 prefill kernel (`ssd.py`'s `chunked_ssd_scan`) mis-compiles in isolation | `torch_neuronx`, a NeuronCore (CPU-only `--dry-run` needs neither) | BF16-noise-floor ratio ~1 (or below) => kernel innocent |
| `moe_router_component.py` | Whether the MoE router (`ops.py`'s `dense_moe_gate`) mis-selects experts on device, single-layer and synthetically stacked | `torch_neuronx`, a NeuronCore (CPU-only `--dry-run` needs neither) | 0 tokens with a different expert selection => router innocent at that depth |
| `dry_run_all.sh` | Whether the scripts themselves are intact (syntax, imports, flags) | nothing beyond Python 3 + PyTorch | exit 0 |

Supporting files, not run directly:

- `mamba2_seqscan.py` -- a neuronx-cc-friendly single-layer Mamba2 selective
  scan, imported by the two trace scripts to patch around a chunked-SSD
  compile failure at short (sub-chunk-size) sequence lengths. See its
  docstring for the specific miscompile it works around.
- `ssd.py`, `ops.py` -- the vLLM Neuron plugin's own NemotronH kernel
  reformulations (`chunked_ssd_scan`, `gated_rmsnorm`, `dense_moe_gate`),
  copied here unmodified so the component tests exercise the exact code the
  plugin ships, not a re-derivation of it.
- `gsm8k_eval.md` -- the `lm_eval` invocation and flag rationale for running
  GSM8K 5-shot against a served endpoint (Trainium or GPU).
- `hlo_dump.md` -- how to dump the HLO graph and the neuronx-cc invocation on
  CPU only (`VLLM_NEURON_CPU_COMPILE=1`), with no NeuronCore required, plus
  how to read the instruction histogram and `NeuronHloVerifier` warnings.
- `deploy-values.template.yaml` -- a chart-agnostic Helm values template
  for serving a community model port on the plugin, covering both the
  single-shot and segmented-prefill build shapes used in this investigation.
- `per_step_logit_diff.md` -- the recommended next experiment: a per-decode-step
  logit/token diff against a CPU reference, to determine whether the
  divergence starts at the first generated token (prefill/compile-time
  candidates) or only at a later decode step (decode-path/SSM-state-handoff
  candidates). Not yet executed in this investigation; see `../README.md`
  for how the result should be read.

## Running the real (non-dry-run) scripts

All four trace/component scripts accept `--dry-run` for a structure-only
check; without it, they require an actual Trainium2 instance with
`torch_neuronx` importable and, for the two model-level scripts, a Hugging
Face environment with NemotronH support (`transformers==5.9.0` in this
investigation; a newer or older `transformers` may or may not carry
`nemotron_h` -- check `python3 -c "from transformers.models.nemotron_h import
modeling_nemotron_h"` first).

```bash
python3 version_isolation_trace.py
python3 plugin_flags_trace.py
python3 chunked_ssd_component.py --seq-lens 256,384
python3 moe_router_component.py --stack-depth 23
```

Each of these compiles at least one NEFF, so expect the trace step alone to
take anywhere from under a minute (`chunked_ssd_component.py`,
`moe_router_component.py`) to roughly 15-20 minutes
(`version_isolation_trace.py`, `plugin_flags_trace.py`, which trace a
16-layer truncated transformer stack rather than a single kernel).
