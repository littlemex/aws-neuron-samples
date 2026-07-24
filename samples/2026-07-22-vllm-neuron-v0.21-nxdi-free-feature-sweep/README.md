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

The whole sweep follows one shape: **launch a server in the background, wait
until it is ready, then run a `verify/*.py` script that hits it.** `launch/serve.sh`
kills any server already holding the NeuronCores before it starts, so switching
between features never requires hunting for stray processes. One server owns the
HBM at a time; to move to the next feature you just launch the next server and
`serve.sh` frees the cores for you.

All the "Expected" outputs below are the actual results measured on a single
`trn2.3xlarge`.

### 0. Set environment variables once per session

Paste this block first in every SSM session; every command below depends on it.

```bash
# --- required: replace with your own value ---
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxx           # Hugging Face token (gated models)

# --- environment (DLAMI defaults; usually leave as-is) ---
export VLLM_NEURON_VENV=/opt/aws_neuronx_venv_pytorch_inference_vllm_0_21_0_1_0_0
export PKG=/work/aws-neuron-samples/samples/2026-07-22-vllm-neuron-v0.21-nxdi-free-feature-sweep
export PATH="/opt/aws/neuron/bin:${VLLM_NEURON_VENV}/bin:${PATH}"
source "${VLLM_NEURON_VENV}/bin/activate"

# --- shared server tuning (reused by every feature) ---
export TP=4                 # tensor-parallel-size (4 NeuronCores)
export MAX_LEN=8192         # max-model-len
export MAX_BT=4096          # max-num-batched-tokens (= prefill bucket width)
export MAX_SEQS=4           # max-num-seqs
export PORT=8000
export CACHE_DIR=/work/neuron_cache   # where NEFF compile cache is kept

cd "${PKG}"
```

Sanity-check the venv:

```bash
python3 -c "import torch, nki, vllm, vllm_neuron; \
print('torch', torch.__version__, '| nki', nki.__version__, '| vllm', vllm.__version__)"
```

Expected:

```
torch 2.11.0+cu130 | nki 0.5.0+... | vllm 0.21.0
```

### 1. Get the package (first time only)

```bash
sudo mkdir -p /work && sudo chown "$(whoami)" /work
git -C /work clone --depth 1 https://github.com/littlemex/aws-neuron-samples.git 2>/dev/null \
  || git -C /work/aws-neuron-samples pull --ff-only
chmod +x "${PKG}"/run_feature_sweep.sh "${PKG}"/launch/*.sh
ls "${PKG}"
```

Expected: `README.md  docs  launch  run_feature_sweep.sh  verify`.

### 2. CPU-only checks (no NeuronCore)

CPU mode, the NKI CPU simulator, and out-of-tree onboarding run without a
NeuronCore. Run them first as a sanity check that the plugin registers and the
model contract works.

```bash
./run_feature_sweep.sh cpu
```

Expected:

```
[SyntheticKV] ... K/V match the reference across all layers (rows of ✓)
generate() returned 8 tokens
RESULT: PASS
```

### 3. Server-based features

Each feature is three steps: launch, wait, verify. The launch command returns
immediately (the server runs in the background and logs to the `--log` file);
once `wait_ready.sh` prints `[ready] up after NNNs`, run the verify scripts.

#### 3-1. Llama 3.1 8B — segmented prefill / structured outputs / tool calling / prefix caching

Structured outputs require async scheduling off plus the enable flag, so one
launch covers all four checks.

```bash
./launch/serve.sh --cache-root "${CACHE_DIR}/llama" --log /tmp/llama.log -- \
  --model meta-llama/Llama-3.1-8B-Instruct --tensor-parallel-size $TP \
  --max-model-len $MAX_LEN --max-num-batched-tokens $MAX_BT --max-num-seqs $MAX_SEQS \
  --no-async-scheduling --enable-auto-tool-choice --tool-call-parser llama3_json \
  --additional-config '{"neuron_config": {"enable_structured_outputs": true}}'

./launch/wait_ready.sh /tmp/llama.log $PORT          # first boot compiles; a few minutes

python3 verify/segmented_prefill.py
python3 verify/structured_outputs.py
python3 verify/prefix_cache_ttft.py
```

Expected:

```
wait_ready:         [ready] up after 361s   (cold boot; compilations 4)
segmented_prefill:  prompt_tokens=6182 -> 2 segment passes / output=' Paris.' / RESULT: PASS
structured_outputs: schema-valid values=yes ... PASS / tool-calling get_weather(...) PASS / RESULT: PASS
prefix_cache_ttft:  prefix_cache_hits_total=43200 (functional proof of cache hits)
```

Note on prefix caching: the hit counter is the functional proof. The TTFT
speedup is quantized to segment/bucket boundaries, so a prompt that fits in a
single prefill bucket shows roughly the same cold/warm TTFT (~0.99x); to see the
latency win the prompt must span more than one segment.

#### 3-2. Compile cache: cold vs warm

Relaunching with the same `--cache-root` reuses the compile cache and boots
faster.

```bash
./launch/serve.sh --cache-root "${CACHE_DIR}/llama" --log /tmp/llama_warm.log -- \
  --model meta-llama/Llama-3.1-8B-Instruct --tensor-parallel-size $TP \
  --max-model-len $MAX_LEN --max-num-batched-tokens $MAX_BT --max-num-seqs $MAX_SEQS
./launch/wait_ready.sh /tmp/llama_warm.log $PORT
```

Expected:

```
[ready] up after 205s   [ready] compile-cache hits: 16
(~43% faster than the 361s cold boot; changing a shape-affecting flag triggers recompilation)
```

#### 3-3. GPT-OSS 20B (MoE) in BF16

MXFP4 execution is Trn3-only. On Trn2 the model runs in BF16 once the HF-config
quantization declaration is cleared and `neuron_config.quantization=bf16` is set.
Its first compilation can exceed 15 minutes, so give `wait_ready.sh` a longer
timeout (the 3rd argument, in seconds).

```bash
./launch/serve.sh --cache-root "${CACHE_DIR}/gptoss" --log /tmp/gptoss.log -- \
  --model openai/gpt-oss-20b --tensor-parallel-size $TP \
  --max-model-len $MAX_LEN --max-num-batched-tokens $MAX_BT --max-num-seqs $MAX_SEQS \
  --hf-overrides '{"quantization_config": {}}' \
  --additional-config '{"neuron_config": {"quantization": "bf16", "num_batched_tokens_buckets": [4096], "num_seqs_buckets": [4]}}'
./launch/wait_ready.sh /tmp/gptoss.log $PORT 1800

python3 verify/gptoss_moe_inference.py
```

Expected:

```
completions -> ' Paris.'
chat -> '17 × 23 = 391. '
RESULT: PASS
```

If `wait_ready` prints `TIMEOUT`, the server may still come up afterwards (the
compile is simply long). Check `curl -s http://localhost:$PORT/v1/models -o /dev/null -w '%{http_code}'`;
a `200` means it is up and you can run the verify script.

#### 3-4. Wide expert parallelism (ep_degree=2)

Full EP (`ep_degree=TP`) exhausts host RAM on `trn2.3xlarge` and dies with
`[F137]`, so drop to `ep_degree=2`.

```bash
./launch/serve.sh --cache-root "${CACHE_DIR}/gptoss_ep" --log /tmp/gptoss_ep.log -- \
  --model openai/gpt-oss-20b --tensor-parallel-size $TP --enable-expert-parallel \
  --max-model-len $MAX_LEN --max-num-batched-tokens $MAX_BT --max-num-seqs $MAX_SEQS \
  --hf-overrides '{"quantization_config": {}}' \
  --additional-config '{"neuron_config": {"quantization": "bf16", "ep_degree": 2, "num_batched_tokens_buckets": [4096], "num_seqs_buckets": [4]}}'
./launch/wait_ready.sh /tmp/gptoss_ep.log $PORT 1800

python3 verify/gptoss_moe_inference.py
```

Expected: the startup log shows EP-tagged workers such as `Worker_TP0_EP0`, and
the answer to "17 × 23" is `391` / `RESULT: PASS`.

#### 3-5. EAGLE3 speculative decoding

Use an AWS-tested speculator (`RedHatAI/gpt-oss-20b-speculator.eagle3`); community
EAGLE3 speculators have an incompatible weight layout. The last value of
`num_batched_tokens_buckets` must equal `max-num-batched-tokens` (2048 here). The
draft+target two-stage compile is heavy, so keep the longer timeout.

```bash
./launch/serve.sh --cache-root "${CACHE_DIR}/eagle" --log /tmp/eagle.log -- \
  --model openai/gpt-oss-20b --tensor-parallel-size $TP \
  --max-model-len 4096 --max-num-batched-tokens 2048 --max-num-seqs $MAX_SEQS \
  --speculative-config '{"method": "eagle3", "model": "RedHatAI/gpt-oss-20b-speculator.eagle3", "num_speculative_tokens": 5}' \
  --hf-overrides '{"quantization_config": {}}' \
  --additional-config '{"neuron_config": {"quantization": "bf16", "on_device_sampling_config": {"temperature": "0"}, "num_batched_tokens_buckets": [2048], "num_seqs_buckets": [4]}}'
./launch/wait_ready.sh /tmp/eagle.log $PORT 1800

python3 verify/eagle3_metrics.py
```

Expected: completions respond and the metrics expose
`spec_decode_num_accepted_tokens` and friends. (Passing `--speculative-config`
automatically disables async scheduling.)

#### 3-6. Multimodal (Qwen3-VL 4B)

The 32B variant does not fit in 96GB HBM, so use 4B. Pass the vision-encoder
config.

```bash
./launch/serve.sh --cache-root "${CACHE_DIR}/qwenvl" --log /tmp/qwenvl.log -- \
  --model Qwen/Qwen3-VL-4B-Instruct --tensor-parallel-size $TP \
  --max-model-len $MAX_LEN --max-num-batched-tokens $MAX_BT --max-num-seqs $MAX_SEQS \
  --additional-config '{"neuron_config": {"num_batched_tokens_buckets": [4096], "num_seqs_buckets": [4]}, "vision_neuron_config": {"num_vision_tokens_buckets": [2048], "vision_attention_block_size": 2048}}'
./launch/wait_ready.sh /tmp/qwenvl.log $PORT

python3 verify/multimodal_qwenvl.py
```

Expected: the model answers `Red` for a solid-red image.

### 4. Metrics (while a server is up)

```bash
curl -s http://localhost:${PORT}/metrics | wc -l
```

Expected: a few hundred lines of Prometheus-compatible metrics.

### 5. Shutdown

Launching the next feature is enough (`serve.sh` frees the cores automatically).
Only run this when you want to stop everything and release the cores:

```bash
pkill -9 -f "VLLM::" 2>/dev/null || true
sleep 45
neuron-ls | grep VLLM || echo "cores free"
```

Stop or terminate the instance itself from your workstation with
`aws ec2 stop-instances` / `terminate-instances` (trn2 is Capacity-Block backed;
if the block is about to expire, terminating is the clean choice).

### Suggested order

0 (env) -> 1 (package) -> 2 (CPU) -> 3-1 -> 3-2 -> 3-3 -> 3-4 -> 3-5 -> 3-6 -> 4 (metrics).
If time is tight, cover the main three first: 2 -> 3-1 -> 3-3. Each feature just
relaunches a server and `serve.sh` frees the cores, so running top to bottom
never conflicts.

## Notes on reproducibility

- First boot compiles NEFFs during warmup and takes minutes; a warm restart with
  the same `--cache-root` reuses them and is much faster (measured 205 s warm vs
  361 s cold for Llama-3.1-8B, ~43% faster). The cache knob is `VLLM_CACHE_ROOT`,
  wired through `launch/serve.sh`.
- `launch/serve.sh` waits for NeuronCores to be released before starting, because
  they free ~30-45 s after a vLLM process exits and the workers are named
  `VLLM::Worker_TP*` (see `docs/FINDINGS.md`).
