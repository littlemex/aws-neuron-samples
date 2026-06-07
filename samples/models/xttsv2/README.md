# XTTSv2 on AWS Trainium (NxD Inference, DLC)

A Coqui [XTTS-v2](https://github.com/coqui-ai/TTS) text-to-speech sample
that runs the heavy GPT decoder on AWS Trainium via NxD Inference inside
an AWS Neuron Deep Learning Container. The CPU-side pieces
(ConditioningEncoder, mel decoder, HifiGAN, tokeniser) stay on Coqui's
upstream Python implementation.

The goal is for the rest of `aws-neuron-samples` (specifically the
`voice-image-edit` demo) to be able to call this server through the
exact same wire contract that the [Polly TTS engine][polly] speaks, just
with `TRAINIUM_TTS_URL` pointed at port 8770.

[polly]: ../../voice-image-edit/app/backend/api/engines/tts/bedrock.py

## Why DLC, and why SDK 2.28.0

The compile path uses the official Neuron DLC pinned to SDK 2.28.0:

```
public.ecr.aws/neuron/pytorch-inference-neuronx:2.9.0-neuronx-py312-sdk2.28.0-ubuntu24.04
```

That tag bundles `neuronx-cc 2.23.6484`. Newer DLC tags (sdk2.29.x,
sdk2.30.x) bundle `neuronx-cc 2.25.3371`, which fails this model's
KV-cache scatter compilation with an internal compiler error:

```
[INTERNAL_ERROR] [NCC_IXRO002] Undefined SB Memloc scatter.1_978_i1
```

The bug is not yet tracked upstream and there is no published flag
workaround. Pinning the DLC tag is the cheapest path to a working
compile that is also reproducible on any other Trainium host.

The host's own Neuron venv (`/opt/aws_neuronx_venv_pytorch_2_9_nxd_inference`)
on the standard Deep Learning AMI is left untouched — XTTSv2 lives
entirely inside the container so other models on the same instance
(Whisper / Qwen3-VL / Qwen-Image-Edit) keep using the AMI's SDK 2.30 venv.

## Layout

```
samples/models/xttsv2/
├── README.md                     ← this file
├── Dockerfile.server             ← DLC + coqui-tts + torchaudio + fastapi
├── compile_xttsv2_nxd.py         ← one-shot Neuron compile, run inside the DLC
├── start.sh                      ← `docker run` launcher (ad-hoc)
├── xttsv2_server.py              ← FastAPI: POST /synthesize, GET /health
├── neuron_xttsv2/                ← NxD Inference integration (verbatim from
│   │                               littlemex/samples/ml_distributed_experiment_collection/
│   │                               xttsv2-nxd-inference)
│   ├── application_gpt.py        ← coordinator: prefill + decode applications
│   ├── config.py                 ← XTTSv2InferenceConfig (max_seq_len=1081)
│   ├── model_wrapper_gpt.py      ← ModelWrapper subclasses for prefill/decode
│   ├── modeling_gpt.py           ← Neuron-friendly GPT modules + KV cache
│   ├── neuron_xttsv2.py          ← bridge: NeuronGPT2InferenceModel
│   └── state_dict.py             ← XTTSv2 → NxD weight remapping
└── tasks/
    ├── xttsv2-precompile.json    ← Task Runner JSON: docker run + DLC compile
    └── xttsv2-server.json        ← Task Runner JSON: docker build + systemd unit
```

## Wire contract

| Method | Path           | Body                                                                                       | Response                                                                                                          |
| ------ | -------------- | ------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------- |
| POST   | `/synthesize`  | `{"text": str, "voice"?: str, "language"?: str, "speed"?: float, "audio_format"?: "wav"}` | `{"audio_b64": "<base64 wav>", "audio_format": "wav", "model_id": "xttsv2", "voice": str?, "language": str?}` |
| GET    | `/health`      | —                                                                                          | `{"status": "ok", "model": "xttsv2", "backend": "nxd_inference", "compiled_dir": "...", "model_dir": "..."}`     |

`speed` is accepted but currently a no-op; XTTSv2 has no native rate
control. `audio_format` is `wav` only — every other value is a 400.
`voice` is a directory name under `XTTSV2_VOICES_DIR`; see Voice cloning
below.

This is the exact contract that `voice-image-edit/app/backend/api/engines/tts/trainium.py`
expects, so flipping the demo to Trainium TTS is a single env var:

```
TRAINIUM_TTS_URL=http://127.0.0.1:8770/synthesize
TRAINIUM_TTS_MODEL_ID=xttsv2
```

## NeuronCore allocation

XTTSv2 binds to a different number of cores depending on the host;
`scripts/deploy-all.sh` picks the profile automatically by querying the
EC2 instance type.

| Instance         | Cores    | TP | Compiled artefact path             | Notes                                                                       |
| ---------------- | -------- | -- | ---------------------------------- | --------------------------------------------------------------------------- |
| `trn2.3xlarge`   | `0-3`    | 4  | `/models/xttsv2-neuron-nxd-tp4`    | The whole chip; whisper is not co-resident in the demo so this is safe.    |
| `trn2.48xlarge`  | `56-63`  | 8  | `/models/xttsv2-neuron-nxd-tp8`    | Two chips, free of whisper (`48-55`), qwen3-vl (`32-47`), qwen-image-edit (`0-31`). |

The two compile paths are deliberately distinct: NEFFs compiled for one
TP are not loadable at another, and `/models` is shared via EFS, so a
naked `/models/xttsv2-neuron-nxd` would let one host silently overwrite
the other's artefacts. The CPU-side checkpoint
(`/models/XTTS-v2/{model.pth,config.json,speakers_xtts.pth}`) is
TP-independent and shared by both profiles.

Override via `--cores`/`--tp-degree` on `start.sh`,
`NEURON_CORES`/`TP_DEGREE`/`COMPILED_MODEL_PATH` in the task json, or
the corresponding `Environment=` lines on the systemd unit.

## Voice cloning

XTTS-v2 is a one-shot voice-cloning model. Drop one (or several) WAV
references into `XTTSV2_VOICES_DIR/<voice_name>/` and pass that name as
the `voice` field. The default lookup is:

```
$XTTSV2_VOICES_DIR/$voice/*.wav
```

If the directory is empty or missing, the server falls back to
`XTTSV2_DEFAULT_VOICE` (default `default`); if that is also empty, the
server falls back to a speaker name baked into `speakers_xtts.pth`
(60+ English-native speakers — the audio will sound non-native for
Japanese). There is no restart needed to add a new voice — the lookup
happens per request.

### Default voice is auto-seeded from Amazon Polly

`tasks/xttsv2-server.json` step `27-fetch-default-voice` synthesises a
short Japanese sample with Polly (`Tomoko/neural`, `us-east-1` because
Polly Neural is not yet GA in sa-east-1) and converts it to a 24 kHz
mono WAV at `/models/xttsv2-voices/default/reference.wav`. XTTSv2 then
clones from a real Japanese-native timbre by default. The step is
idempotent (skipped when `reference.wav` already exists). Override via:

```
XTTSV2_REFERENCE_VOICE_ID       (default: Tomoko)
XTTSV2_REFERENCE_VOICE_REGION   (default: us-east-1)
XTTSV2_REFERENCE_VOICE_TEXT     (default: a fixed Japanese sample sentence)
```

The EC2 instance role needs `polly:SynthesizeSpeech` (granted by the
voice-image-edit ApiStack as part of its standard IAM bundle, so any
deploy via `scripts/deploy-all.sh --base-stack-name <stack>` already
covers this).

## Compile

The compile is a one-shot ~1-2 minute step on a Trainium instance
running the SDK 2.28 DLC. Run it via the Task Runner so the artefacts
persist across deploys:

```bash
AWS_PROFILE=<your-aws-profile> bash samples/voice-image-edit/scripts/deploy-all.sh \
  --base-stack-name <STACK> --region <REGION> \
  --only xttsv2-precompile
```

Or directly on the host with docker:

```bash
docker run --rm \
  --device /dev/neuron0 \
  --shm-size 8g \
  -e NEURON_RT_VISIBLE_CORES=0-3 \
  -e NEURON_RT_NUM_CORES=4 \
  -e NEURON_RT_VIRTUAL_CORE_SIZE=2 \
  -e NEURON_LOGICAL_NC_CONFIG=2 \
  -e MALLOC_ARENA_MAX=2 \
  -v /models:/models \
  -v $(pwd):/src:ro \
  -w /src \
  --entrypoint /bin/bash \
  public.ecr.aws/neuron/pytorch-inference-neuronx:2.9.0-neuronx-py312-sdk2.28.0-ubuntu24.04 \
  -lc "pip install --quiet 'coqui-tts==0.26.*' 'soundfile>=0.12' && \
       pip install --quiet 'torchaudio==2.9.*' --extra-index-url https://download.pytorch.org/whl/cpu && \
       python compile_xttsv2_nxd.py \
         --model-path /models/XTTS-v2 \
         --output-dir /models/xttsv2-neuron-nxd \
         --tp-degree 4 \
         --seq-len 1081"
```

The script writes `.compile_metadata.json` next to `prefill/` and
`decode/` so subsequent runs short-circuit.

### Why BF16 (not FP16)

FP16 has a 5-bit exponent and overflows on the 30-layer XTTSv2 GPT
decoder's attention softmax — the upstream experiment measured 68.8%
WER on FP16 vs ~0% on BF16. trn2 uses BF16 as its native dtype so this
is also the natural fast path.

### Why 16 GB swap

Tracing both prefill and decode applications transiently allocates ~3 GB
of intermediate tensors per phase. Default trn2.3xlarge instance memory
is large enough but the glibc allocator fragments badly under tracing,
and the NxD compiler also forks subprocesses; allocating 16 GB swap
prevents the OOM-killer from striking mid-compile. The precompile task
provisions this automatically (`05-ensure-swap`).

## Serve

```bash
AWS_PROFILE=<your-aws-profile> bash samples/voice-image-edit/scripts/deploy-all.sh \
  --base-stack-name <STACK> --region <REGION> \
  --only xttsv2-server
```

This:

1. Builds the runtime image (`xttsv2-server:sdk2.28.0-ja`) by extending
   the DLC base with `coqui-tts==0.26.*`, `torchaudio==2.9.*`,
   `fastapi`, `uvicorn`, and `soundfile`.
2. Drops a `xttsv2-server.service` systemd unit that launches a
   `docker run --rm --device /dev/neuron0 ...` container, with
   `Restart=always` so a transient failure recovers automatically.
3. Polls `/health` for up to 600 s while the model warm-loads ~3 GB
   of NEFF.

Locally / interactively:

```bash
docker build -t xttsv2-server:sdk2.28.0-ja -f Dockerfile.server .
bash start.sh   # runs the same docker run as the systemd unit
```

## Wire it into voice-image-edit

The TTS slot in voice-image-edit's `/manage` page already lists
`trainium` alongside the four `bedrock_polly_*` voices. To make the
demo's "🔊 講評を読み上げ" button route to XTTSv2 instead of Polly:

1. Pick `trainium` on `/manage` (persisted to localStorage).
2. Or set the server-wide default with
   `TTS_ENGINE_DEFAULT=trainium` on `voice-image-edit-api.service`.
3. Make sure the API's environment also has
   `TRAINIUM_TTS_URL=http://127.0.0.1:8770/synthesize`.

Switching back to Polly is the same flip in reverse — both engines are
always live as long as their dependencies (Polly IAM / XTTSv2 systemd
unit) are in place.

## Pitfalls

- **DLC SDK pin.** sdk2.29.x and sdk2.30.x bundle `neuronx-cc 2.25.3371`,
  which trips `[NCC_IXRO002] Undefined SB Memloc scatter.1_978_i1` on
  this model's KV-cache scatter. Stay on `sdk2.28.0` until the bug is
  fixed upstream — the DLC tag is fixed in `Dockerfile.server`
  (`FROM ...:sdk2.28.0-ubuntu24.04`) and in both task json files.
- **Reset the KV cache between requests.** Without
  `gpt_inference.token_count = 0; gpt_inference.cached_prefix_emb = None;
  gpt_inference.is_prefill = True` between synthesise calls, the second
  and following requests degrade into garbled audio. The server does
  this automatically in `_reset_kv_cache()`.
- **`seq_len=1081` is fixed at compile time.** Inputs longer than ~402
  text tokens are silently truncated by Coqui TTS today; sentence-level
  splitting is a follow-up.
- **`torchaudio 2.9` + Coqui ≥ 0.27 hard-require `torchcodec`** which has
  no working CPU build for the Neuron AMI. We pin `coqui-tts==0.26.*`
  (the maintained idiap fork; the last release that does not import
  torchcodec at module load) and install `torchaudio==2.9.*` from the
  CPU index. The server installs a soundfile-backed monkey patch for
  `torchaudio.load` at import time so XTTS can read speaker reference
  WAVs without an FFmpeg backend.
- **Upstream `TTS>=0.22` does not support Python 3.12.** The DLC ships
  Python 3.12, which is why the maintained `coqui-tts` fork is required
  (same `import TTS` namespace).
- **DLC SageMaker entrypoint.** The DLC ships a SageMaker
  `dockerd-entrypoint.py` that turns plain `docker run image bash -lc
  '...'` into a `tail -f /dev/null` no-op. Always use
  `--entrypoint /bin/bash` (we override it everywhere — Dockerfile.server,
  start.sh, the systemd unit, and the precompile task).
- **Two-phase weight injection.** `compile()` runs against a zero-init
  state dict (`xttsv2_checkpoint_path=""`); the real `.pth` is only
  applied at `load_weights()` time, by way of the coordinator stamping
  the path onto the config and calling `shard_checkpoint()`.

See the original NxD-Inference experiment for the full design notes:

- <https://zenn.dev/tosshi/articles/ffc359901ea1cc>
- <https://zenn.dev/tosshi/articles/81840c7c10dddd>
- <https://github.com/littlemex/samples/tree/main/ml_distributed_experiment_collection/xttsv2-nxd-inference>
