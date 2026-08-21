# GSM8K 5-shot evaluation against a vLLM completions endpoint

This is the `lm_eval` invocation used to score a served model on GSM8K,
against both a Trainium (vLLM Neuron plugin) endpoint and a GPU (vanilla
vLLM) endpoint serving the same weights. It uses the `local-completions`
model type, which talks to any OpenAI-compatible `/v1/completions` endpoint,
so the same command works against either backend by changing `base_url` and
`model`.

## Prerequisites

```bash
python3 -m venv lmeval-venv
source lmeval-venv/bin/activate
pip install lm-eval[api] transformers
```

`tokenizer_backend=huggingface` makes `lm_eval` build the few-shot prompt and
count tokens itself using the real Hugging Face tokenizer, rather than
sending tokenized requests to the endpoint. This is required because the
Neuron endpoint's request path expects text completions, not the tokenized
`/v1/completions` variant.

## Command

```bash
export ENDPOINT_BASE_URL="http://localhost:8000/v1/completions"   # port-forwarded server
export SERVED_MODEL_NAME="nemotron-h"                              # must match --served-model-name
export TOKENIZER_ID="nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16"    # HF repo id, for the tokenizer only
export MAX_LEN=4096                                                 # must be <= the server's --max-model-len

lm_eval --model local-completions \
  --model_args "model=${SERVED_MODEL_NAME},base_url=${ENDPOINT_BASE_URL},tokenizer=${TOKENIZER_ID},tokenizer_backend=huggingface,num_concurrent=1,tokenized_requests=False,max_length=${MAX_LEN},timeout=1200" \
  --trust_remote_code \
  --tasks gsm8k \
  --num_fewshot 5 \
  --limit 40 \
  --gen_kwargs temperature=0
```

Notes on the flags:

- `num_concurrent=1` — keep this at 1 against a single-chip Trainium server
  with `max_num_seqs=1`; higher concurrency will queue or error, not
  parallelize, and makes elapsed time harder to interpret.
- `tokenized_requests=False` — send plain text, not pre-tokenized integer
  arrays; the Neuron plugin's OpenAI server expects text prompts.
- `--limit 40` — a 40-prompt sample is enough to distinguish "works" (accuracy
  in the 60-90% range, matching a GPU reference) from "structurally broken"
  (accuracy at or near 0%). Raise it for a tighter confidence interval once
  you know the endpoint is stable.
- `timeout=1200` — generous per-request timeout; large `max_model_len`
  segmented builds can have long first-request latency after a cold compile.
- Reported metrics are `strict-match` and `flexible-extract` exact_match.
  `strict-match` requires the exact GSM8K answer format; `flexible-extract`
  pulls the last number in the generation. Report both; a large gap between
  them usually means the model gets the right number but not the expected
  formatting, not that reasoning itself is wrong.

## GPU reference endpoint

To get a same-model GPU reference, serve the identical checkpoint with
vanilla vLLM on CUDA and point the same `lm_eval` command at it:

```bash
python3 -m vllm.entrypoints.openai.api_server \
  --model nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16 \
  --served-model-name nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16 \
  --tensor-parallel-size 2 \
  --max-model-len 4096 \
  --dtype bfloat16 \
  --trust-remote-code
```

Then set `SERVED_MODEL_NAME` and `TOKENIZER_ID` to the same HF repo id and
rerun the same `lm_eval` command against `http://<gpu-host>:8000/v1/completions`.
Comparing strict-match between the Trainium and GPU runs, with everything
else held constant (same weights, same dtype, same few-shot count, same
`--limit`), is the cleanest same-model cross-backend signal available.

## Observed results (see ../README.md for full context)

| Backend | SDK / stack | strict-match | flexible-extract |
|---|---|---|---|
| GPU, bf16, same weights | vLLM 0.20.0 / CUDA | 0.875 | 0.60 |
| GPU, FP8 variant | vLLM 0.20.0 / CUDA | — | 0.70 |
| Trainium, bf16, same weights | Neuron SDK 2.31 / vllm-neuron 0.21 | 0/5 sampled (~0) | ~0 |

The Trainium 2.31 figure was measured on a small sample because segmented
prefill compile time made a full run impractical at the time (see
`hlo_dump.md` and ../README.md, "Known limitations", for the segmented-prefill compile-time caveat on SDK 2.32).
