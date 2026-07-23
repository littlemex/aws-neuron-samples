# Suspected doc/implementation issues in vLLM Neuron v0.21.0.1.0.0

Found while running the feature sweep on `trn2.3xlarge`. Source references are
pinned to tag `v0.21.0.1.0.0` (commit `ae6c10eff6ec748e958045241aaca0288e8ddaa8`).
Behaviors marked "confirmed on hardware" have no corresponding source link.

These are suitable to file as GitHub issues against
[vllm-project/vllm-neuron](https://github.com/vllm-project/vllm-neuron) (Apache-2.0).

## 1. `NEURON_COMPILED_ARTIFACTS` is documented but unreferenced in code (silently ignored)

- Confidence: high (clear doc-vs-code divergence)
- Severity: Medium (no crash, but a silent misconfiguration with real cost/latency impact)

The docs present `NEURON_COMPILED_ARTIFACTS` as the compile-cache path knob in three files:
[reference-configuration.md](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/docs/guides/reference-configuration.md)
("Path to cache/load compiled models. Skips recompilation when valid artifacts exist."),
[features-guide.md](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/docs/guides/features-guide.md),
and [how-to-profile-workloads.md](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/docs/guides/how-to-profile-workloads.md).

The variable has zero references in any `.py` file in the installed package. The
cache path is controlled only by `VLLM_CACHE_ROOT`
([envs.py L341](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/vllm_neuron/envs.py#L341)).
Confirmed on hardware: setting `NEURON_COMPILED_ARTIFACTS` had no effect; NEFFs
went to the default `~/.cache/vllm/neuron/compile_cache`, while `VLLM_CACHE_ROOT`
did redirect them.

Impact: a user who follows the docs believes the cache is persisted, but it lands
in the default path and is lost on container/instance recreation, with no warning.

Fix: correct the three docs to `VLLM_CACHE_ROOT`, or make the code honor
`NEURON_COMPILED_ARTIFACTS` as a fallback.

## 2. Option A (`pip install -e .`) does not pull a torch-2.11-compatible Neuron runtime

- Confidence: high (packaging gap)
- Severity: Medium as a bug, High as an onboarding blocker; workaround exists (DLAMI venv)

[setup-guide.md](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/docs/getting-started/setup-guide.md)
Option A states `pip install -e .` "installs the vLLM Neuron plugin along with
vLLM and all required Neuron SDK packages." But
[requirements/core.txt](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/requirements/core.txt)
declares no Neuron runtime dependency (`torch-neuronx` / `libtorch-neuronx-lite`).
vLLM `0.21.0` pins torch `2.11.0`, while the general `torch-neuronx` is
torch-2.9-based and pulls torch back to 2.9. Confirmed on hardware: Option A did
not run; a `neuron` device-type `RuntimeError` occurred, and only the DLAMI venv
(with `libtorch-neuronx-lite 2.11`) worked.

Fix: declare a torch-2.11-compatible Neuron runtime in `core.txt`, or annotate
Option A that a Neuron runtime is separately required and recommend the DLAMI venv
during Beta.

## 3. Stale TODO comment contradicts the implemented prefix-caching guard

- Confidence: medium (low runtime impact, misleading comment)
- Severity: Low-Medium; documentation issue, good first issue

[neuron_model_runner.py L409-412](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/vllm_neuron/vllm/worker/neuron_model_runner.py#L409)
carries a TODO saying prefix caching is "not yet supported on Neuron / will fail
silently or cause incorrect behavior / No validation". However
[L669](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/vllm_neuron/vllm/worker/neuron_model_runner.py#L669)
already raises a `ValueError` guarding APC (requires segmented prefill), and
[features-guide.md](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/docs/guides/features-guide.md)
states prefix caching is enabled by default. Confirmed on hardware: APC works
correctly and deterministically. The TODO ("No validation", "not yet supported")
is stale.

Fix: update or remove the L409-412 TODO to reflect the implemented guard and the
actual default-on behavior.

## Not bugs, but under-documented constraints

- `kv_segment_size_buckets` accepts a single value only ("Only one segment size is
  currently supported"). Confirmed on hardware.
- Structured outputs and EAGLE3 are mutually exclusive with async scheduling
  (`--no-async-scheduling`); structured outputs additionally needs
  `neuron_config.enable_structured_outputs=true`. Confirmed on hardware.
- EAGLE3 speculators must be safetensors with the AWS Neuron weight layout;
  community `.bin` EAGLE3 checkpoints (`midlayer.*` naming) do not load. Confirmed
  on hardware.
