# patches

Five minimal diffs that turn `Physical-Intelligence/openpi` at commit
`c23745b5ad24e98f66967ea795a07b2588ed6c79` into a working LoRA fine-tune
of `pi05_aloha_pen_uncap` on AWS Trainium2 (`trn2.3xlarge`).

`bootstrap.sh` applies these in lexicographic order via `git apply`.

| File | Target | Role |
|---|---|---|
| `01-train-init-cpu-eager.patch` | `scripts/train.py` | Replace `jax.jit(init)` with CPU-eager init + `jax.device_put(state_sharding)`. Avoids `NCC_ETUP002` (tuple custom call) and the 7.54 GB HLO constant capture warning. |
| `02-disable-augmax.patch` | `src/openpi/models/model.py` | Dead-code the augmax block (`if train and False:`). The HSV `argmax` inside `augmax.ColorJitter` lowers to a 2-operand reduce that hits `NCC_ISPP027`. The `import augmax` line is left as-is, so the `augmax` package still has to be in the venv. |
| `03-beta-to-uniform.patch` | `src/openpi/models/pi0.py` | Replace `jax.random.beta(time_rng, 1.5, 1)` with `jax.random.uniform(0.001, 0.999)` in `compute_loss`. Beta's rejection sampling explodes partition 5 with hundreds of Threefry ops and crashes `HLOToTensorizer`. |
| `04-no-rng-split.patch` | `src/openpi/models/gemma.py`, `src/openpi/models/vit.py` | Defensive: drop `dropout: True` from `nn.scan(split_rngs=...)`. dropout is 0.0 here, but `nn.scan` still materialises rng splits in the graph. |
| `05-add-pi05-lora-config.patch` | `src/openpi/training/config.py` | Add a new `TrainConfig` `pi05_aloha_pen_uncap_lora` (`paligemma_variant="gemma_2b_lora"`, `action_expert_variant="gemma_300m_lora"`, `batch_size=4`, `freeze_filter`, `ema_decay=None`). |

## Apply manually

```bash
cd <openpi-checkout>
git checkout c23745b5ad24e98f66967ea795a07b2588ed6c79
for P in /path/to/samples/openpi-pi05-lora-trn2/patches/*.patch; do
    git apply "${P}"
done
```

After applying all five, `git status -s` should report 6 modified files
(`scripts/train.py` plus `src/openpi/{models/{gemma,model,pi0,vit}.py,
training/config.py}`) and `git diff --stat` should report
`6 files changed, 51 insertions(+), 11 deletions(-)`. Each patch passes
`git apply --check` in isolation; ordering is irrelevant, but `bootstrap.sh`
applies them lexicographically for determinism.

## If you upstream them

These patches stay minimal on purpose. For an upstream PR, gating would be
appropriate:

- `03-beta-to-uniform.patch` changes the training-time distribution; gate it
  behind a `USE_NEURON_COMPATIBLE_TIME` flag (default off).
- `02-disable-augmax.patch` similarly changes augmentation; gate it behind
  `if train and not os.environ.get("OPENPI_DISABLE_AUGMAX")`.
- `01-train-init-cpu-eager.patch` is benign on GPU too (init runs on CPU
  anyway), but the donate semantics differ; gate behind a platform check
  (`jax.devices()[0].platform == "neuron"`) to keep GPU performance.
