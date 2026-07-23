# Feature sweep findings (vLLM Neuron v0.21.0.1.0.0 on trn2.3xlarge)

Environment: single `trn2.3xlarge` (4 NeuronCores, 96 GB HBM), vLLM Neuron
`v0.21.0.1.0.0`, vLLM `0.21.0`, Neuron SDK `2.31.0`, DLAMI-provided venv
`/opt/aws_neuronx_venv_pytorch_inference_vllm_0_21_0_1_0_0`.

Source references are pinned to tag `v0.21.0.1.0.0`
(commit `ae6c10eff6ec748e958045241aaca0288e8ddaa8`). Measurements without a source
link were confirmed on live hardware.

## Coverage matrix

| Feature | Result | Evidence |
|---|:---:|---|
| Environment (DLAMI venv) | PASS | pip Option A installs vLLM (torch 2.11) + the plugin but no Neuron runtime (`nki`), so model loading fails with `ModuleNotFoundError: nki`; the DLAMI venv carries the aligned set. See SUSPECTED-BUGS.md #2. |
| CPU mode | PASS | `VLLM_NEURON_CPU_MODE=1`; compile backend `vllm_neuron`, dist `gloo`. |
| NKI CPU simulator | PASS | `verify/cpu_nki_simulator.py`: add / exp*mul kernels match a NumPy reference within 0.00 error. |
| CPU compilation | PASS | `VLLM_NEURON_CPU_COMPILE=1` produced 6 NEFF (93 MB) with no NeuronCore. `neuronx-cc` must be on PATH ([backend.py L391](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/vllm_neuron/compile/backend.py#L391)). |
| torch.compile + compile cache | PASS | cold 249 s vs warm restart 140 s (44% faster); warm logs "Local cache hit ... Skipping graph capture"; a config change forces a recompile (no false hit). Cache knob is `VLLM_CACHE_ROOT` ([envs.py L341](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/vllm_neuron/envs.py#L341)); `NEURON_COMPILED_ARTIFACTS` is a no-op (see SUSPECTED-BUGS.md #1). |
| Segmented prefill | PASS | `verify/segmented_prefill.py`: a 6183-token prompt runs in 2 segment passes and answers correctly. `kv_segment_size_buckets` accepts a single value only. |
| Automatic prefix caching | PASS | Deterministic, correct output; TTFT gain is quantized to segment/bucket boundaries. A 5252-token shared prefix gives cold 2.265 s vs warm 1.146 s (1.98x). APC requires segmented prefill ([neuron_model_runner.py L669](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/vllm_neuron/vllm/worker/neuron_model_runner.py#L669)). |
| Structured outputs | PASS | JSON-schema enforcement returns schema-valid output. Requires `--no-async-scheduling` ([neuron_model_runner.py L5259](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/vllm_neuron/vllm/worker/neuron_model_runner.py#L5259)) and `enable_structured_outputs=true`. |
| Tool calling | PASS | `get_weather(city=Melbourne)` tool_call generated correctly. |
| GPT-OSS 20B (MoE) | PASS | BF16 on Trn2 via `--hf-overrides '{"quantization_config": {}}'` + `neuron_config.quantization=bf16` ([gpt_oss/factory.py L46](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/vllm_neuron/model/gpt_oss/factory.py#L46)). "17x23" answered "391". |
| Wide expert parallelism | PASS | full EP (ep_degree=4) exhausts host RAM (`[F137] neuronx-cc forcibly killed`); `ep_degree=2` (hybrid with TP=4) compiles and serves. Workers named `Worker_TP*_EP*`. |
| EAGLE3 speculative decoding | PASS | AWS-tested speculator `RedHatAI/gpt-oss-20b-speculator.eagle3`; metrics: drafts=41, draft_tokens=205, accepted=23, per-position accept 17/5/1/0/0. Community `.bin` speculators with `midlayer.*` layout are incompatible. |
| Multimodal (Qwen3-VL 4B) | PASS | image + text: a red image is recognized as "Red". 32B is too large for this box. |
| Production metrics | PASS | `/metrics` exposes ~390 lines with histograms. |
| Profiler API | PASS | `--profiler-config '{"profiler": "cuda"}'` mounts `/start_profile` and `/stop_profile` (both HTTP 200). Full trace capture needs extra memory / `NEURON_RT_INSPECT_ENABLE`. |
| Out-of-tree model integration | PASS | `verify/oot_synthetic_e2e.py`: SyntheticNeuronModel runs `LLM.generate()` end to end (resolve -> get_kv_spec -> bind_kv_cache -> forward -> generate). |
| Transformers V5 | PASS | transformers 5.14.1 in use. |
| Disaggregated inference (NiXL) | not tested | Needs 2 instances + EFA (RDMA); out of scope on a single node. See [disaggregated-inference design](https://github.com/vllm-project/vllm-neuron/blob/ae6c10eff6ec748e958045241aaca0288e8ddaa8/docs/design/vllm/disaggregated-inference.md). |

## Instance-size takeaway

Everything except disaggregated inference was verified on a single `trn2.3xlarge`.
A larger node is truly required only for disaggregated (NiXL) inference, which
needs a second instance and EFA. Full EP and very large models are memory-bound,
not architecture-bound, and can be exercised at smaller degree / size on a 3xlarge.

## Operational gotchas learned

- NeuronCores are released ~30-45 s after a vLLM process dies; workers are named
  `VLLM::Worker_TP*` / `VLLM::EngineCore`, so `pkill -f vllm.entrypoints` misses
  them and the next launch fails with "cores busy (ret=-16)". `launch/serve.sh`
  handles this.
- On a box without an EFA-type ENI, set `NEURON_SKIP_EFA_AFFINITY=1`.
- APC + segmented prefill require `max_num_batched_tokens` to be a supported
  segment size AND strictly less than `max_model_len` (equal values disable
  segmentation and then collide with APC).
