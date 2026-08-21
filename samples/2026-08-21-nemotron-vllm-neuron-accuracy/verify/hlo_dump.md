# Dumping HLO / neuronx-cc compiler artifacts without a NeuronCore

The vLLM Neuron plugin can trace and compile a model on CPU-only hardware
using meta tensors, which is enough to inspect the HLO graph, the
neuronx-cc invocation, and the tensorizer's own warnings — without ever
touching a NeuronCore. This is the cheapest way to check whether a graph is
being lowered faithfully from the PyTorch FX graph before spending
compile-cluster time on a real device.

## How to trigger a CPU-only compile

```bash
export VLLM_NEURON_CPU_COMPILE=1
python3 -m vllm.entrypoints.openai.api_server \
  --model <your-model> \
  --served-model-name nemotron-h \
  --tensor-parallel-size 4 \
  --max-model-len 256 \
  --max-num-seqs 1 \
  --dtype bfloat16 \
  --trust-remote-code
```

With `VLLM_NEURON_CPU_COMPILE=1`, the model is instantiated under
`torch.device("meta")`, so no real weights or device memory are needed;
`torch.compile` still runs and neuronx-cc is still invoked, tracing through
compilation and emitting its normal logs and intermediate artifacts to the
compile cache directory even though there is no NeuronCore to execute on.
This is the same code path the plugin's `load_model()` uses for a normal
device compile (see the "NEURON_CC_FLAGS is ignored" note below).

## What you get, and where to look

In the compile cache directory (`NEURON_COMPILED_ARTIFACTS`, or the default
cache root), each compiled subgraph produces:

- `graph.hlo` — the HLO graph handed to neuronx-cc. Compare this against the
  PyTorch FX graph dump (`TORCH_COMPILE_DEBUG=1` or `torch._dynamo` graph
  dumps) to confirm the lowering from FX to HLO is faithful — i.e. no
  operator was silently dropped, reordered in a way that changes semantics,
  or substituted.
- `passes/NN-<pass-name>.hlo` — one file per internal compiler pass, in
  order. Diffing consecutive passes shows exactly which pass introduced a
  given transformation (e.g. an implicit int-to-float conversion, a layout
  change, a fusion).
- `log-neuron-cc.txt` — the full neuronx-cc stdout/stderr, including the
  `NeuronHloVerifier` warnings (see below) and the instruction histogram.
- `command.txt` — the exact neuronx-cc command line the plugin constructed.
  Useful for reproducing a specific compile outside of vLLM, or for
  confirming which flags actually reached the compiler (see the
  "NEURON_CC_FLAGS is ignored" note directly below.

## Reading the instruction histogram

`log-neuron-cc.txt` includes a per-opcode instruction count/percentage
breakdown for the compiled graph, e.g.:

```
reshape   14.98%
convert   13.71%
broadcast 11.24%
dot        8.86% (6126 dots)
reduce     0.58%
iota            140
```

A high `convert` percentage is worth cross-referencing against the
`NeuronHloVerifier` warnings below — a large fraction of the graph doing
implicit dtype conversions is a signal (not proof) that precision-sensitive
lowering decisions are happening across a wide swath of the graph, not in
one isolated operator. A `dot` count in the thousands for a 50+ layer hybrid
model is expected (every attention projection, every MoE expert matmul,
every Mamba2 in/out projection is a `dot`); use it as a sanity baseline, not
as evidence on its own.

## Reading NeuronHloVerifier warnings

The compiler's HLO verifier emits warnings like:

```
[WARNING] Operands of 64-bit integer type are implicitly converted to 32-bit
integer or floating point types. This may cause accuracy issues.
[WARNING] Operands of 32-bit integer type are implicitly converted to
floating point types.
```

These indicate that somewhere in the graph, an integer computation (a common
place: index/argmax/iota-based logic, such as a MoE router's top-k
selection) is being silently widened to float. The active default is
`--implicit-integer-downcast=all`. You can force
`--implicit-integer-downcast=none` by editing the plugin's constructed
`hlo2tensorizer_opts` string in the plugin's model runner, and re-run the
same reproduction:

- If the output changes, the downcast was a contributing cause — keep
  digging into which specific operator hit the implicit conversion.
- If the output does not change, the downcast path in that graph is not the
  cause, even though the warning is real; do not treat the warning's
  presence alone as root cause without confirming behaviorally that toggling
  it changes anything.

In the NemotronH investigation, forcing `--implicit-integer-downcast=none`
did not change the wrong output, which ruled it out as the cause of the
residual 2-hop-arithmetic failure — see ../README.md, "Root-cause path",
for the full list of ruled-out workarounds.

## Command used to inspect the neuronx-cc invocation directly

`command.txt` in the compile cache directory contains the exact command;
a representative example from this investigation:

```
neuronx-cc --auto-cast=none --verbose=35 -O1 \
  --internal-hlo2tensorizer-options="--modular-flow-mac-threshold=10" \
  --internal-backend-options="--enable-verifier=false" \
  ...
```

Note `--enable-verifier=false` in `--internal-backend-options` disables the
verifier's own gating behavior for the actual compile, while
`log-neuron-cc.txt` still records the warnings it would have raised — read
the log even when the verifier itself is not blocking the build.
