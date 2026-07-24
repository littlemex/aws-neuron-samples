# vLLM Neuron v0.21 — NxDI-free feature sweep on Trainium2

A reproducible hands-on verification of the **vLLM Neuron plugin `v0.21.0.1.0.0`**
on a single `trn2.3xlarge`. This is the release that **drops the NxD Inference
dependency** and moves model implementations directly into the plugin, so it is a
large architectural change from the 0.5.x line. This package runs every feature
of the release that fits on one node and records exactly what works, what needs a
workaround, and what is out of scope.

Verification date: 2026-07-22. Versions: vLLM Neuron `v0.21.0.1.0.0`, vLLM
`0.21.0`, Neuron SDK `2.31.0`. Source references are pinned to commit
`ae6c10eff6ec748e958045241aaca0288e8ddaa8`.

## What this package covers

| Feature | Result | Verify script / how |
|---|:---:|---|
| CPU mode + NKI CPU simulator | PASS | `verify/cpu_nki_simulator.py` (no NeuronCore) |
| CPU compilation (NEFF without hardware) | PASS | `VLLM_NEURON_CPU_COMPILE=1` server launch |
| torch.compile + compile cache | PASS | cold vs warm restart timing (`launch/wait_ready.sh`) |
| Segmented prefill (long context) | PASS | `verify/segmented_prefill.py` |
| Automatic prefix caching | PASS | `verify/prefix_cache_ttft.py` |
| Structured outputs + tool calling | PASS | `verify/structured_outputs.py` |
| GPT-OSS 20B (MoE) BF16 inference | PASS | `verify/gptoss_moe_inference.py` |
| Wide expert parallelism | PASS | `--enable-expert-parallel` + `ep_degree=2` |
| EAGLE3 speculative decoding | PASS | `verify/eagle3_metrics.py` |
| Multimodal (Qwen3-VL 4B) | PASS | `verify/multimodal_qwenvl.py` |
| Out-of-tree model onboarding | PASS | `verify/oot_synthetic_e2e.py` |
| Production metrics / profiler API | PASS | `/metrics`, `/start_profile` |
| Disaggregated inference (NiXL) | out of scope | needs 2 nodes + EFA |

Full evidence with source permalinks is in [`docs/FINDINGS.md`](docs/FINDINGS.md).
Documentation/implementation issues discovered along the way are in
[`docs/SUSPECTED-BUGS.md`](docs/SUSPECTED-BUGS.md).

## Layout

```
2026-07-22-vllm-neuron-v0.21-nxdi-free-feature-sweep/
├── README.md
├── run_feature_sweep.sh        # runs the CPU-only checks; prints server recipes
├── launch/
│   ├── serve.sh                # server launcher (core cleanup + EFA skip + cache root)
│   └── wait_ready.sh           # poll /v1/models, report cold/warm + cache hits
├── verify/                     # one script per feature (see table above)
└── docs/
    ├── FINDINGS.md             # coverage matrix + operational gotchas
    └── SUSPECTED-BUGS.md       # doc/impl inconsistencies worth reporting
```

## Prerequisites

- A `trn2.3xlarge` launched from the Neuron Multi-Framework DLAMI (Ubuntu 24.04),
  which ships the venv `/opt/aws_neuronx_venv_pytorch_inference_vllm_0_21_0_1_0_0`.
  See the setup helper in
  [`setup/single-node`](https://github.com/littlemex/aws-neuron-samples/tree/main/setup/single-node).
- A Hugging Face token (`HF_TOKEN`) for gated models such as Llama-3.1-8B.

Why the DLAMI venv rather than `pip install -e .`: the pip path pulls torch 2.11
(vLLM's pin) while the general `torch-neuronx` is torch-2.9-based, so it does not
run as-is. Details in `docs/SUSPECTED-BUGS.md` #2.

## How to run

Every check follows the same shape: **launch a server in the background, wait
until it is ready, then run a `verify/*.py` script that hits it.** `launch/serve.sh`
kills any server already holding the NeuronCores before it starts, so you never
have to hunt for stray processes when switching features.

### 1. Set environment variables once per session

```bash
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx     # gated models (Llama-3.1-8B, etc.)
export VLLM_NEURON_VENV=/opt/aws_neuronx_venv_pytorch_inference_vllm_0_21_0_1_0_0
export PATH="/opt/aws/neuron/bin:${VLLM_NEURON_VENV}/bin:${PATH}"
source "${VLLM_NEURON_VENV}/bin/activate"
export TP=4 MAX_LEN=8192 MAX_BT=4096 MAX_SEQS=4 PORT=8000
export CACHE_DIR=/work/neuron_cache        # where NEFF compile cache is kept
```

### 2. CPU-only checks (no NeuronCore)

CPU mode, the NKI CPU simulator, and out-of-tree onboarding run without a
NeuronCore. Use them as a first sanity check that the plugin registers and the
model contract works.

```bash
./run_feature_sweep.sh cpu
```

Expect NKI kernels to match a NumPy reference and the synthetic model's
`generate()` to print `RESULT: PASS`.

### 3. Server-based checks

Example: Llama-3.1-8B covering segmented prefill, structured outputs + tool
calling, and prefix caching in one launch. Structured outputs require async
scheduling off plus the enable flag.

```bash
./launch/serve.sh --cache-root "${CACHE_DIR}/llama" --log /tmp/llama.log -- \
  --model meta-llama/Llama-3.1-8B-Instruct --tensor-parallel-size $TP \
  --max-model-len $MAX_LEN --max-num-batched-tokens $MAX_BT --max-num-seqs $MAX_SEQS \
  --no-async-scheduling --enable-auto-tool-choice --tool-call-parser llama3_json \
  --additional-config '{"neuron_config": {"enable_structured_outputs": true}}'
./launch/wait_ready.sh /tmp/llama.log $PORT          # first boot compiles; takes minutes

python3 verify/segmented_prefill.py
python3 verify/structured_outputs.py
python3 verify/prefix_cache_ttft.py
```

Restarting with the same `--cache-root` reuses the compile cache and boots much
faster (measured 205 s warm vs 361 s cold for Llama-3.1-8B; `wait_ready.sh`
reports the cache-hit count).

GPT-OSS 20B (MoE) in BF16 on Trn2, optionally with expert parallelism. Its first
compilation can exceed 15 minutes, so give `wait_ready.sh` a longer timeout (the
3rd argument, in seconds):

```bash
./launch/serve.sh --cache-root "${CACHE_DIR}/gptoss" --log /tmp/gptoss.log -- \
  --model openai/gpt-oss-20b --tensor-parallel-size $TP --enable-expert-parallel \
  --max-model-len $MAX_LEN --max-num-batched-tokens $MAX_BT --max-num-seqs $MAX_SEQS \
  --hf-overrides '{"quantization_config": {}}' \
  --additional-config '{"neuron_config": {"quantization": "bf16", "ep_degree": 2, \
     "num_batched_tokens_buckets": [4096], "num_seqs_buckets": [4]}}'
./launch/wait_ready.sh /tmp/gptoss.log $PORT 1800
python3 verify/gptoss_moe_inference.py
```

The EAGLE3 and multimodal (Qwen3-VL 4B) launch recipes are documented at the top
of `verify/eagle3_metrics.py` and `verify/multimodal_qwenvl.py`. To stop
everything and free the cores when you are done: `pkill -9 -f "VLLM::" ; sleep 45`.

## Notes on reproducibility

- First boot compiles NEFFs during warmup and takes minutes; a warm restart with
  the same `--cache-root` reuses them and is much faster (measured 205 s warm vs
  361 s cold for Llama-3.1-8B, ~43% faster). The cache knob is `VLLM_CACHE_ROOT`,
  wired through `launch/serve.sh`.
- `launch/serve.sh` waits for NeuronCores to be released before starting, because
  they free ~30-45 s after a vLLM process exits and the workers are named
  `VLLM::Worker_TP*` (see `docs/FINDINGS.md`).
