# PROJECT_STATUS.md

**Last updated**: 2026-06-17
**Status**: 1-step LoRA fine-tune reproduces with identical metrics across two
environments. Patches are frozen at `samples/openpi-pi05-lora-trn2/patches/*.patch`.

## What works

- 5 patches against `Physical-Intelligence/openpi` commit `c23745b` are enough
  to run `pi05_aloha_pen_uncap_lora` for one step on `trn2.3xlarge`.
- `reproduce.sh --use-capacity-block --slot <NAME> --watch` from a laptop drives
  the whole pipeline: EC2 launch -> openpi clone -> patch apply -> venv ->
  pi05_base ckpt sync -> 1 step train.
- Re-applying `patches/*.patch` to a fresh clone gives bit-identical
  `loss=0.0647 / grad_norm=0.4076 / param_norm=1803.7698` (verified on
  2026-06-17 against `i-0e1b65e879b3412e5` in `ap-southeast-4`).

## Reference environment

| Item | Value |
|---|---|
| EC2 used for verification | `i-0e1b65e879b3412e5` (`ap-southeast-4`) |
| CFN stack | `neuron-openpi-mel` |
| Capacity Block | `cr-08cbc80ac6442ab28` (96 h, expires ~ 2026-06-20 11:30 UTC) |
| EFS | `fs-0bb164d1b423207fd` (subpath `/openpi-jax/main`) |
| openpi base commit | `c23745b5ad24e98f66967ea795a07b2588ed6c79` |
| pi05_base ckpt | `/mnt/local/cache-coder/openpi/openpi-assets/checkpoints/pi05_base/params` (12.5 GiB) |

## Measured metrics

| Phase | cold (compile + first ckpt save) | warm (cached compile + ckpt save) |
|---|---:|---:|
| 1-step wall time | **19:53** | **~80 s** (37.5 s train + 43.6 s ckpt save) |
| Step 0 loss | 0.0647 | 0.0647 |
| Step 0 grad_norm | 0.4076 | 0.4076 |
| Step 0 param_norm | 1803.7698 | 1803.7698 |

The ~44 s ckpt save tail is EFS bandwidth (~11 MiB/s); the Neuron train_step
itself should drop to single digits with a tighter benchmark loop.

## Patches (in apply order)

| # | File | Effect | Original error |
|---|---|---|---|
| 01 | `01-train-init-cpu-eager.patch` | CPU-eager `init_train_state` | `NCC_ETUP002` |
| 02 | `02-disable-augmax.patch` | Disable augmax HSV `argmax` | `NCC_ISPP027` |
| 03 | `03-beta-to-uniform.patch` | `jax.random.beta` -> `uniform` | `INTERNAL: .` (partition 5 in `HLOToTensorizer`) |
| 04 | `04-no-rng-split.patch` | Defensive `nn.scan(split_rngs)` cleanup | (defensive) |
| 05 | `05-add-pi05-lora-config.patch` | Add `pi05_aloha_pen_uncap_lora` config | `NCC_EVRF009` |

## Open follow-ups

| Item | Priority | Status |
|---|---|---|
| 10-step warm profile (per-component) | medium | runnable via `reproduce.sh --num-train-steps 10` |
| Augmax impact on policy quality | medium | needs eval script + A/B run |
| Beta vs. uniform convergence sweep | medium | gate behind `OPENPI_USE_BETA_TIME` first |
| Upstream openpi PR | low | flag-gated versions of 02 / 03 |
| Zenn article addendum | in progress | "Pi0.5 LoRA FT reproduction" section in `openpi-jax-trainium2-nki.md` |
