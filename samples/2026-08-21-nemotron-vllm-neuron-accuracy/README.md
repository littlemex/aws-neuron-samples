# NemotronH on vLLM Neuron — a deterministic on-device reasoning regression, cause not yet isolated

A reproducible record of an accuracy investigation into serving **NemotronH**
(the hybrid Mamba2 / MoE / Attention text backbone behind
`nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16`) on the **vLLM Neuron plugin**.
The same PyTorch graph, same weights, same greedy prompts are correct on CPU
and on a CUDA GPU, but degrade on Trainium: short factual completions and
long-range recall stay correct, while multi-step and positional reasoning
(2-hop arithmetic, transitive comparisons, GSM8K) fail, deterministically and
reproducibly. This package is the minimal, reproducible slice of that
investigation: the probe suite, the component-level isolation scripts, and
the deployment/measurement recipes.

**Read this before the isolation results below.** An earlier draft of this
investigation concluded, by elimination, that the plugin's full-graph
integration compile was "the" culprit. An adversarial review of that
reasoning found the elimination invalid — every exonerating experiment
changed two or more variables relative to the failing configuration at once,
so no single stage was validly ruled in or out — and found that the specific
mechanism proposed (compounding numerical drift in stacked MoE routing) is
contradicted by this package's own evidence (see "Rejected hypotheses"
below). This README reflects the corrected, calibrated status: **what is
established, what candidates remain live, and what the single next
experiment is** — not a verdict.

### Established / Open

| | |
|---|---|
| **Established** | The wrong output on the accelerator is deterministic and byte-identical across two different Mamba2 scan algorithms and across two different attention-kernel prefill paths. Combined with the CPU/GPU parity and the FP8-on-GPU result below, this localizes the fault to **a shared code path above kernel selection** — the plugin's compile frontend, a compiler pass, runtime state management, or weight staging — and rules out non-deterministic numerical drift and precision sensitivity as the mechanism. The failure is task-selective (multi-step/order/arithmetic fails; short completions and long-range recall survive), and on the failing arithmetic prompts the **first generated token is already wrong**, so the defect is observable at prefill/first-logit time, not only after several decode steps. |
| **Open** | *Which* component in that shared path is at fault. No experiment below holds all-but-one variable fixed against the real failing configuration (plugin frontend + full ~30B MoE-containing model + autoregressive decode), so none of them — including "the plugin's full-graph compile" as a monolithic claim — has been validly isolated. See "Ranked candidates" and "Next experiment" below. |

Versions: vLLM Neuron plugin `0.21.0.1.0.0` (Neuron SDK `2.31.0`) and
`0.24.0.1.1.0` (Neuron SDK `2.32.0`). Model: `NemotronHForCausalLM`, served
through a community port of the model to the vLLM Neuron plugin (not part of
the upstream plugin as of this writing). GPU reference: vLLM `0.20.0` on
CUDA, same checkpoint. All numbers below are greedy (temperature 0).

## What this shows

| Environment | Reasoning probes (12 total) | GSM8K 5-shot, `limit=40` (strict-match / flexible-extract) |
|---|:---:|:---:|
| CPU (Hugging Face reference) | matches reference exactly | not run (GPU is the fast same-model baseline) |
| GPU, bf16, same weights | 11 / 12 | **0.875** / 0.60 |
| GPU, FP8 variant of the same architecture | not run | 0.70 (lower precision than bf16, still far above Trainium) |
| Trainium, SDK 2.31 | 5 / 12 | **0.000** / 0.000 |
| Trainium, SDK 2.32 | 9 / 12 (2-hop arithmetic still fails) | not measured — segmented-prefill compile-time regression, see Known limitations |

The FP8-on-GPU result is the sharpest single data point: FP8 is *lower*
precision than bf16, yet it reasons correctly on GPU while the *same-precision*
bf16 checkpoint fails structurally on Trainium. Precision is not the
variable that explains the gap. It is also, independently, why "compounding
numerical drift" is not a viable mechanism for this failure (see "Rejected
hypotheses" below): a mechanism sensitive enough to tiny per-layer numeric
differences would be far more sensitive to an actual precision *downgrade*,
and FP8-on-GPU shows the opposite.

## Component isolation results

Each item below tested one candidate cause with the smallest experiment that
could distinguish it, cheapest first. All the trace/component experiments
compare a device output against a CPU reference on the exact same
model/kernel; "faithful" means the device output matches the CPU output to
within ordinary BF16 rounding, not that it is bit-identical. **Read these as
individually-informative results, not as a valid elimination chain** — see
the variable matrix immediately after, which is the reason this package no
longer claims a single root cause.

1. **Model implementation.** The CPU-only PyTorch graph (no custom
   kernels — the Hugging Face pure-PyTorch fallback path) matches the
   Hugging Face reference exactly, including a full greedy generation of the
   2-hop arithmetic prompt. The model's math is correct.
2. **Numerical precision (bf16).** Ruled out by the GPU bf16-vs-FP8 result
   above: a *lower*-precision variant reasons correctly on GPU. If the model
   were precision-fragile, FP8 should fail at least as often as bf16; it
   does not.
3. **A single operator's precision.** Seven fp32-precision workarounds were
   tried on-device — the MoE combine, the Mamba2 SSD scan, the MoE `relu^2`
   activation, the Mamba2 pre-scan path (conv1d/SiLU/softplus), the
   attention kernel replaced with a plain fp32 causal SDPA that matches the
   CPU reference operator-for-operator, and two compiler-flag variants of
   the integer-downcast setting. None changed the wrong output at all —
   the failing generation stayed byte-identical across every workaround.
   This rules out any single operator's precision as the cause.
4. **The compiler version, in isolation** (`verify/version_isolation_trace.py`).
   A real NemotronH-family checkpoint, truncated to its first 16 decoder
   layers (covering all three layer types — Mamba2, attention, MLP — and
   the model's no-positional-encoding design, where position information is
   carried only through the Mamba2 recurrence), traced with
   `torch_neuronx.trace` using neuronx-cc's **default** flags: **faithful**
   (cosine similarity to the CPU reference 0.999896, matching top-1 token).
   The same compiler version that the plugin uses compiles this hybrid graph
   correctly through a different (non-plugin) compile path. The compiler
   version itself is not the culprit.
5. **The plugin's own compiler flags, in isolation**
   (`verify/plugin_flags_trace.py`). The plugin does not read
   `NEURON_CC_FLAGS`; it constructs its own neuronx-cc invocation internally
   (see `verify/hlo_dump.md`). Re-tracing the *same* truncated model with
   the plugin's exact flags (`--auto-cast=none -O1
   --internal-hlo2tensorizer-options=--modular-flow-mac-threshold=10
   --internal-backend-options=--enable-verifier=false`) scored the *same*
   cosine similarity (0.999896) as the default-flags control. The flags are
   not the culprit.
6. **The Mamba2 prefill kernel, in isolation**
   (`verify/chunked_ssd_component.py`). The plugin's self-contained
   `chunked_ssd_scan` kernel, traced standalone at the model's real Mamba2
   dimensions, scored a BF16-noise-floor ratio of 0.82 (256-token input, two
   chunks) and 0.75 (384 tokens, three chunks) — device error at or below
   ordinary BF16 rounding. The kernel compiles faithfully; not the culprit.
7. **The MoE router, in isolation** (`verify/moe_router_component.py`). The
   plugin's `dense_moe_gate` top-k router, traced standalone as a single
   layer, produced **zero** tokens with a different expert selection out of
   256 versus the CPU reference — faithful in isolation. However, a
   synthetic chain of 23 router layers (the number of MoE layers in the
   real 52-layer hybrid), each layer's input nudged by the previous layer's
   output as a stand-in for layer stacking, produced 8/256 tokens with a
   *different* expert selection. This demonstrates a mechanism — not yet a
   measurement on the real model — by which per-layer differences too small
   to matter individually could compound across many stacked MoE layers
   into an actual wrong-expert selection.

## Why this is not a valid elimination chain

Every item above compiled faithfully in isolation — but none of those
experiments was run under the actual failing configuration. Each one changed
two or more variables relative to it at once:

| | Frontend | Layer count | MoE present | Execution mode |
|---|---|---|---|---|
| **Failing configuration** | plugin's `torch.compile` backend | ~52 (full model) | yes | autoregressive decode |
| Step 4/5 (compiler version, plugin flags) | `torch_neuronx.trace` | 16 (truncated) | **no** | single forward pass |
| Step 6 (Mamba2 kernel) | `torch_neuronx.trace` | 1 kernel, standalone | no | single forward pass |
| Step 7 (MoE router) | `torch_neuronx.trace` | router only, standalone | router only | single forward pass |

Holding "all but one variable fixed" is what makes an isolation experiment
valid; nothing above does that against the real failing case. Concretely,
none of the experiments in this package ever exercised: a complete MoE layer
end to end (router *and* dispatch/permute/gather *and* the grouped expert
GEMMs *and* combine/scatter — only the router's top-k selection was tested);
the plugin's actual frontend on any passing case (the truncated-model
experiments used the vendor's generic trace API, not the plugin's
`torch.compile` capture path); weight loading/layout at full 52-layer scale;
or, most importantly given the symptom, **the decode path and the
prefill-to-decode handoff of the Mamba2 recurrent state** — every experiment
above is a single forward pass, and this model carries all positional
information exclusively in that state.

## Rejected hypotheses

**Compounding numerical drift in stacked MoE routing.** An earlier draft of
this investigation proposed that per-layer numeric differences too small to
matter individually accumulate across the 23 stacked MoE layers and flip
top-k expert selections, based on a synthetic 23-layer router stack (step 7)
showing 8/256 flipped selections under an arbitrary layer-to-layer coupling.
This is rejected: it contradicts two of this package's own results.
(1) The wrong output is **byte-identical** across two different Mamba2 scan
algorithms and across two different attention-kernel prefill paths — chaotic
noise accumulation is sensitive to summation order and kernel choice, so a
noise-compounding mechanism would be expected to produce *different* wrong
outputs across those variants, not an identical one. Byte-identical failure
instead points to a deterministic bug in a code path shared by both variants.
(2) The FP8-on-GPU result: FP8 is a far larger perturbation than ordinary
BF16 rounding, so if occasional near-tie expert flips broke this model, FP8
should fail *at least* as often as bf16 does; it does not, and reasons
correctly. Additionally, the synthetic stack used an arbitrary coupling with
no relation to the model's real inter-layer transfer function, and no
GPU/CPU baseline was run on the same synthetic stack to check whether GPU
(which works end to end) would show similar flip counts under the same
synthetic setup — so the experiment cannot distinguish "flips matter" from
"flips are a benign, ever-present artifact of stacking anything."

## Ranked candidates (open, not established)

In descending order of how well each explains *all* of: byte-identical
failure across kernels, FP8-on-GPU working, only multi-step/order-dependent
reasoning failing, short completions and long-range recall surviving, and
the SDK 2.31-to-2.32 partial fix.

1. **Prefill-to-decode Mamba2/SSM state handoff, in the plugin's runtime.**
   Explains the full symptom profile: position lives only in SSM recurrent
   state, so a handoff bug (state not carried, wrong stride, stale, or
   re-zeroed between decode steps) would selectively destroy order-dependent
   reasoning while leaving attention-mediated recall — a separate code path
   — intact. Weakness: zero direct evidence yet; every experiment above was
   a single forward pass, so this path was never exercised in isolation.
   Untested, not proven.
2. **Static-graph capture bakes prefill-specific semantics into the decode
   graph** (shape or position specialization at trace time). Predicts the
   same symptom profile as (1) and is hard to distinguish from it without
   the next experiment below; treat as a sibling hypothesis.
3. **A shared compiler pass miscompiling the SSM state-update op** (layout
   canonicalization or fusion of the recurrence). Explains determinism and
   the SDK partial fix, but sits awkwardly with the byte-identical result
   across *two different scan algorithms* — different scans should lower
   differently, so a bug surviving both suggests the fault is above kernel
   lowering, which favors (1)/(2) over this.
4. **A dispatch/permute/combine index bug in the plugin's MoE implementation**
   (as distinct from the router's top-k selection, which tested faithful in
   isolation — see step 7 above; the dispatch/gather/combine machinery was
   never tested). Explains determinism and the SDK partial fix, but requires
   an ad hoc explanation for why recall and short completions — which
   traverse the same MoE layers on the same device — survive.
5. **Weight loading/layout defect at full 52-layer scale.** Explains
   determinism, but corrupted weights should degrade short completions and
   recall too, which they do not; a weak fit.

KV-cache/attention decode bugs are effectively ruled out by long-range
verbatim recall surviving, since recall requires attention over the cache to
work correctly.

## Next experiment

The single next step, at essentially zero infrastructure cost, is a
**per-step logit diff**: greedy-decode a failing arithmetic prompt and
compare the model's logits against the CPU reference at every generated
position, not just the final text. See `verify/per_step_logit_diff.md` for
the procedure. On the data already in this package, the *first* generated
token on the failing arithmetic prompts is already wrong (the plugin
generates `" twice"` where the CPU reference generates `" 6"`), which points
toward prefill/compile-time causes (candidates 2, 4, 5 above) rather than a
pure decode-step defect — but this has not yet been confirmed with a
step-by-step logit comparison, self-consistency check, or an activation dump
of the SSM state itself, all of which `per_step_logit_diff.md` describes.
Run that experiment before attempting to isolate any single candidate
further; it is designed to split the remaining hypothesis space in half at
near-zero cost.

## Layout

```
2026-08-21-nemotron-vllm-neuron-accuracy/
├── README.md
└── verify/
    ├── README.md                       # per-script isolation table
    ├── dry_run_all.sh                   # syntax + --dry-run smoke test, no hardware needed
    ├── probes.py                        # 12-prompt reasoning probe suite (needs a served endpoint)
    ├── version_isolation_trace.py       # step 4: compiler version, in isolation
    ├── plugin_flags_trace.py            # step 5: plugin's own compiler flags, in isolation
    ├── chunked_ssd_component.py         # step 6: Mamba2 prefill kernel, in isolation
    ├── moe_router_component.py          # step 7: MoE router, in isolation
    ├── mamba2_seqscan.py                # dependency: neuronx-cc-friendly Mamba2 scan
    ├── ssd.py                           # dependency: the plugin's own chunked_ssd_scan / conv1d
    ├── ops.py                           # dependency: the plugin's own gated_rmsnorm / dense_moe_gate
    ├── gsm8k_eval.md                    # lm_eval GSM8K 5-shot recipe (Trainium and GPU)
    ├── hlo_dump.md                      # CPU-only HLO/neuronx-cc-invocation dump, no NeuronCore needed
    ├── per_step_logit_diff.md           # next experiment: per-decode-step logit diff vs CPU
    └── deploy-values.template.yaml      # chart-agnostic Helm values for single-shot / segmented builds
```

## Prerequisites

- A `trn2.3xlarge` (or equivalent Trainium2 capacity) able to pull
  `public.ecr.aws/neuron/...` images, for the full end-to-end reproduction
  (serving + probes + GSM8K).
- For the component-isolation scripts specifically (`version_isolation_trace.py`,
  `plugin_flags_trace.py`, `chunked_ssd_component.py`,
  `moe_router_component.py`): a Python environment with `torch_neuronx`
  installed and a NeuronCore available. `chunked_ssd_component.py` and
  `moe_router_component.py` have no other dependency; the two model-level
  trace scripts additionally need a `transformers` build with NemotronH
  support (`transformers==5.9.0` was used in this investigation).
- A community port of `NemotronHForCausalLM` to the vLLM Neuron plugin (a
  `model/nemotron_h/` directory implementing the plugin's model interface).
  This guide assumes you already have one; it is not part of the upstream
  `vllm-neuron` plugin as of this writing.
- Optionally, a CUDA GPU for the same-model reference (2x 24GB-class GPUs is
  enough for `--tensor-parallel-size 2` at bf16 for this 30B-class
  checkpoint).

Nothing in this package requires anything beyond the public Neuron SDK / DLC
and the public vLLM Neuron plugin. No private or pre-release software is
used anywhere in this investigation's reproducible portion.

## How to run

### 0. Smoke-test the scripts (no hardware needed)

```bash
cd verify
./dry_run_all.sh
```

This syntax-checks every script and exercises each one's `--dry-run` path.
`probes.py`, `chunked_ssd_component.py`, and `moe_router_component.py` run
real CPU-only computation in dry-run mode (network calls / device tracing
are what get skipped); the two model-level trace scripts report a
missing-dependency note if your local Python environment lacks
`transformers==5.9.0`'s NemotronH support, which is expected off-target, and
still exit 0. See `verify/README.md` for the full per-script isolation
table.

### 1. Serve the model on Trainium

Inject the community model port into the plugin's registry and start the
vLLM OpenAI server (see `verify/deploy-values.template.yaml` for a
chart-agnostic version of the same steps):

```bash
python3 -c 'import importlib.util, os; print(os.path.dirname(importlib.util.find_spec("vllm_neuron").origin))'
# copy your model/nemotron_h/ directory into <plugin-dir>/model/nemotron_h/,
# then patch <plugin-dir>/model/registry.py to add the import and registry entry.

python3 -m vllm.entrypoints.openai.api_server \
  --model nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16 \
  --served-model-name nemotron-h \
  --tensor-parallel-size 4 \
  --max-model-len 256 \
  --max-num-seqs 1 \
  --dtype bfloat16 \
  --trust-remote-code
```

Single-shot builds at `max_model_len=256` compile in roughly 30-40 minutes
on the SDK 2.32 stack. See Known limitations for the segmented-prefill
build needed for GSM8K.

### 2. Run the reasoning-probe suite

```bash
export PROBE_BASE_URL="http://<endpoint-host>:8000/v1/completions"
export PROBE_MODEL="nemotron-h"
python3 verify/probes.py "trainium-single-shot"
```

Expected on SDK 2.32 (9/12; all three arithmetic probes still fail):

```
capital_0      [PASS] expect=Paris  gen=' Paris.'
...
arith_bob      [FAIL] expect=6      gen=' twice as many apples as Bob has...'
cmp_box        [PASS] expect=red    gen=' red one.'
anticopy       [PASS] expect=4      gen=' 4.'
== trainium-single-shot: 9/12 pass ==
```

### 3. Run GSM8K

See `verify/gsm8k_eval.md` for the full `lm_eval` command, flag rationale,
and the GPU-reference invocation. This needs a segmented-prefill build (see
Known limitations); the SDK 2.31 stack was used for the Trainium GSM8K
number above because SDK 2.32's segmented-prefill compile-time regression
made a full run impractical at the time of this investigation.

### 4. Run the component-isolation scripts

```bash
cd verify
python3 version_isolation_trace.py       # ~15-20 min: traces a 16-layer truncated model
python3 plugin_flags_trace.py            # ~15-20 min: same model, plugin's own compiler flags
python3 chunked_ssd_component.py --seq-lens 256,384   # under a minute
python3 moe_router_component.py --stack-depth 23      # under a minute
```

Each prints a `[RESULT ...]` line with the relevant metric (cosine
similarity, BF16-noise-floor ratio, or expert-selection mismatch count) and
a `[verdict]` line explaining how to read it. See the docstring at the top
of each script and `verify/README.md` for the full isolation table.

### 5. Run the next experiment: per-step logit diff

The isolation scripts above are all single-forward-pass experiments; none
of them exercises the decode path. `verify/per_step_logit_diff.md` describes
the next, currently-unrun experiment: greedy-decode a failing prompt against
a served endpoint and diff the logits at every step against the CPU
reference, to determine whether the divergence starts at the first token
(favoring prefill/compile-time candidates) or only appears later
(favoring the decode-path/SSM-state-handoff candidates). See "Ranked
candidates" and "Next experiment" above for how to read the result.

## Known limitations

These are the specific points where narrowing the cause further from
outside the plugin's own machinery was not possible, and why:

- **Tracing the full model does not fit.** `torch_neuronx.trace` does not
  shard weights or page activations the way the plugin's tensor-parallel
  serving path does. Tracing the full ~50-layer, ~30B-parameter hybrid
  produces a NEFF that does not fit a single NeuronCore's HBM and fails
  with an allocation error. `version_isolation_trace.py` and
  `plugin_flags_trace.py` truncate to the first 16 layers instead, which
  keeps every layer type present but cannot speak to whether the full
  model's additional depth or its MoE layers contribute independently.
- **A minimal synthetic config does not compile.** Building a small,
  synthetic full hybrid (all three layer types, random weights, small
  hidden size) to test integration effects cheaply was attempted; tracing
  it triggered a native `double free` crash in the compiler toolchain,
  unrelated to the accuracy question. The real checkpoint, truncated,
  avoided this and was used instead.
- **Per-layer first-divergence localization on the real deployment is
  blocked by an integration gap, not a hardware limit.** The plugin ships a
  `tensor_capture` mechanism (see `verify/hlo_dump.md` for related tooling)
  that hooks named modules and writes their activations to disk during a
  real forward pass, intended for exactly this kind of layer-by-layer
  comparison against a reference. In this investigation, capture hooks
  registered correctly for all 52 layers and the deployment reproduced the
  bug as expected, but **no captures were written**. The most likely cause
  is that this model port's serving-path forward function returns logits
  only (a deliberate design choice for managing Mamba2's recurrent state
  outside the plugin's attention-only KV-cache contract), and the capture
  mechanism's extra tuple outputs are not threaded through that return
  path. Resolving this requires a small change to the model port's forward
  function, not a change to the plugin.
- **Comparing the plugin's `torch.compile` frontend against `torch_xla`
  directly did not produce a numerical result.** An attempt to trace the
  same truncated model with `torch.compile(backend="openxla")` — the
  `torch_xla`-based frontend the plugin's own backend builds on — failed
  with a `torch_xla` tensor-type plumbing error unrelated to model
  correctness, before any device computation ran.
- **Segmented-prefill compile time regressed severely between SDK 2.31 and
  2.32** for this model's graph shape. On SDK 2.31, `max_model_len=4096`
  compiled and served successfully. On SDK 2.32, the same configuration
  exceeded the default 3600-second tensor-parallel barrier and never came
  up; lowering to `max_model_len=2048` with the barrier raised to 10800s
  still did not finish within about 90 minutes; lowering further to
  `max_model_len=1024` with the barrier raised to 14400s compiled the
  prefill subgraph in about 40 minutes but the decode subgraph did not
  finish within 110+ minutes. This blocked measuring GSM8K on the SDK 2.32
  stack in this investigation; the reported Trainium GSM8K number above is
  from SDK 2.31. Raise `VLLM_NEURON_BARRIER_TIMEOUT` well above its default
  if you attempt a segmented build on 2.32, and budget hours, not minutes.

If you hit a similar on-device-only accuracy regression on a different
model or SDK stack, the isolation *order* used here — model correctness
(CPU) -> precision sensitivity (bf16 vs a lower-precision variant, if one
exists) -> single-operator workarounds -> compiler version in isolation ->
compiler flags in isolation -> individual kernels in isolation — is
reusable regardless of the specific model, and is cheaper at every step
than jumping straight to full-model, full-device debugging.
