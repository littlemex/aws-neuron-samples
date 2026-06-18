# openpi-pi05-lora-trn2

A reproducible package for **LoRA fine-tuning Physical Intelligence's openpi (Pi0.5)**
on a single `trn2.3xlarge`. It LoRA-izes `pi05_aloha_pen_uncap` and runs one training
step end-to-end via a single `reproduce.sh` invocation.

Cold start (pi05_base ckpt restore + JAX -> HLO -> neuron-cc + first ckpt save) is
roughly 20 minutes; with a warm compile cache, one step is **37.5 s of train work +
43.6 s of EFS-bound ckpt save = ~80 s total**. The Neuron computation itself is much
faster than that; the ~44 s tail is purely the EFS write bandwidth (~11 MiB/s).

## What this package does

Public openpi at commit `c23745b` is GPU-first, so on Trainium2 it hits four compiler
walls in sequence. The patches in `patches/01..05` defuse all four with the smallest
possible diff (54 insertions / 11 deletions across 6 files).

| # | Symptom | Root cause | Patch |
|---|---|---|---|
| 1 | `NCC_EVRF009` (HBM 49 GB > 24 GB) | Full FT optimizer state exceeds Trainium2 HBM | Add a `pi05_aloha_pen_uncap_lora` config that LoRA-izes the model (`05-add-pi05-lora-config.patch`) |
| 2 | `NCC_ETUP002` (tuple custom call) | `jax.jit(init)(rng, partial_params)` lowers a 22-tensor tuple into `NeuronBoundaryMarker-Start`, which the compiler refuses | Run `init` as CPU eager and `jax.device_put(state_sharding)` afterwards (`01-train-init-cpu-eager.patch`) |
| 3 | `NCC_ISPP027` (multi-operand reduce) | `augmax.ColorJitter`'s HSV path uses `jnp.argmax`, which lowers to a 2-operand reduce | Dead-code the augmax block in `preprocess_observation` (`02-disable-augmax.patch`) |
| 4 | `XlaRuntimeError: INTERNAL: .` (empty msg) | `jax.random.beta` rejection sampling explodes partition 5 with hundreds of Threefry ops (xor/shift-*) and crashes `HLOToTensorizer` | Replace `jax.random.beta(time_rng, 1.5, 1)` with `jax.random.uniform` (`03-beta-to-uniform.patch`) |

`04-no-rng-split.patch` is a defensive patch that turns off `dropout` rng splitting
in `nn.scan`; it does not by itself unblock any of the four walls but reduces graph
churn and keeps the dropout-disabled invariant explicit. Five patches in total
defuse the four walls.

The full investigation log lives in [docs/EXPERIMENT.md](./docs/EXPERIMENT.md).

## Layout

```
samples/openpi-pi05-lora-trn2/
├── README.md                # this file
├── reproduce.sh             # one-shot wrapper: deploy.sh + SSM-driven bootstrap
├── bootstrap.sh             # runs on EC2: clone openpi -> apply patches -> venv -> 1 step train
├── patches/
│   ├── README.md
│   ├── 01-train-init-cpu-eager.patch
│   ├── 02-disable-augmax.patch
│   ├── 03-beta-to-uniform.patch
│   ├── 04-no-rng-split.patch
│   └── 05-add-pi05-lora-config.patch
└── docs/
    ├── EXPERIMENT.md        # investigation log for the four walls
    └── PROJECT_STATUS.md    # current results and follow-ups
```

## Prerequisites

- `trn2.3xlarge` capacity (Capacity Block of 24h is enough for a smoke run, or
  on-demand if your account has it)
- `AWS_PROFILE` exported and `aws sts get-caller-identity` working
- The repo's own `setup/single-node/scripts/deploy.sh` is functional (CDK + jq + Node.js)

`reproduce.sh` calls `setup/single-node/scripts/deploy.sh` internally. For Capacity
Block runs, register the reservation id in SSM Parameter Store via
`setup/single-node/scripts/manage-capacity-block.sh save-params --slot <NAME>`,
then pass `--slot <NAME>` to `reproduce.sh`.

## One-shot reproduction

```bash
# 1) Capacity Block (recommended)
AWS_PROFILE=<your-profile> \
samples/openpi-pi05-lora-trn2/reproduce.sh \
  --region ap-southeast-4 \
  --use-capacity-block --slot openpi-pi05-lora \
  --watch
```

```bash
# 2) Spot for a quick check
AWS_PROFILE=<your-profile> \
samples/openpi-pi05-lora-trn2/reproduce.sh \
  --region ap-southeast-4 \
  --use-spot \
  --watch
```

```bash
# 3) Existing stack: only run the bootstrap on a known instance
AWS_PROFILE=<your-profile> \
samples/openpi-pi05-lora-trn2/reproduce.sh \
  --region ap-southeast-4 \
  --skip-deploy --instance-id i-0xxxxxxxxxxxxxxxx \
  --num-train-steps 1 --batch-size 4 --watch
```

`--watch` polls the SSM command every 30 seconds and prints the last 40 lines of
output when it finishes. Without `--watch`, you get the `CommandId` back and can
poll later with `aws ssm get-command-invocation`.

## Expected output

On success, `/work/openpi-pi05-lora-reproduce/runs/<EXP_NAME>.log` ends with:

```
Step 0: grad_norm=0.4076, loss=0.0647, param_norm=1803.7698
```

`param_norm` is the L2 norm of the trainable LoRA weights right after init from
`pi05_base`. `loss` is FlowMatching MSE; ~0.06 is the expected order of magnitude
for the first step.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `wandb.errors.errors.UsageError: No API key configured.` | The bootstrap passes `WANDB_MODE=disabled` and `--no-wandb-enabled`. If you call `train.py` directly, mirror those settings or `export WANDB_API_KEY=...`. |
| `sh: 1: neuronx-cc: not found` | `bootstrap.sh` puts the venv `bin` first in `PATH`. If you call `train.py` from a different shell, prepend `/work/openpi-pi05-lora-reproduce/.venv/bin` to `PATH`. |
| `NCC_EARG002 ... unrecognized arguments: --tmpdir / --no-cache` | `NEURON_CC_FLAGS` only accepts `--logfile` and `--verbose=*` here. Use `NEURONX_DUMP_TO=<dir>` instead of `--tmpdir`. |
| Capacity Block expired and the instance is gone | `setup/single-node/scripts/deploy.sh --recover` (within ~half a day) or `--force-recreate` (after the AWS retention TTL). Then call `reproduce.sh --skip-deploy --instance-id <new>` to rerun the bootstrap. |

## Related

- Upstream openpi: <https://github.com/Physical-Intelligence/openpi>
- Inference-side companion (Pi0.5 on Trainium2 down to 0.819 s/step warm) is the
  Zenn article series "Pi0 を JAX-NeuronX で AWS Trainium2 で動かすまで" /
  "Pi0.5 を Trainium2 で 7.7× 高速化".
- Repo root `setup/single-node/`: deploy.sh, manage-capacity-block.sh, and
  the rest of the EC2 plumbing.
