# EXPERIMENT.md

Investigation log for getting `Physical-Intelligence/openpi`
(commit `c23745b5ad24e98f66967ea795a07b2588ed6c79`) to LoRA fine-tune
`pi05_aloha_pen_uncap` on a `trn2.3xlarge`. Four compiler walls fell one at a
time and we ended up with five small patches that fully reproduce.

Final result (cold compile + ckpt save included):

```
Step 0: grad_norm=0.4076, loss=0.0647, param_norm=1803.7698
```

## Environment

- Region: `ap-southeast-4` (Melbourne), Capacity Block on `trn2.3xlarge`
- AMI: `ami-0b01a144f994bc0b3` (Neuron DLAMI)
- NeuronX Compiler: `2.25.3371.0+f524f7f8`
- Python: 3.12.3
- jax-neuronx: `0.10.0.1.0.9913+41e8ced2`
- libneuronxla: `3.0.2891.0+e2a4b1f5`

`deploy.sh` flags (used as-is from `setup/single-node/scripts/deploy.sh`):

```
--create-efs --efs-subpath /openpi-jax/main \
--install-claude-code --enable-explorer
```

## The four walls

### Wall 1: NCC_EVRF009 (HBM 49 GB > 24 GB)

Full fine-tune for `pi05_aloha_pen_uncap` needs ~49 GB of HBM (parameters +
optimizer state) and the chip has 24 GB:

```
[ERROR] [NCC_EVRF009] Total tensor I/O 53.6 GB exceeds available HBM 25.8 GB
Largest input tensor: f32[18,2,2048,16384] (input33)
                       f32[18,16384,2048] (input34)
```

#### Fix (`05-add-pi05-lora-config.patch`)

Add a LoRA-specific config in `config.py`:

```python
TrainConfig(
    name="pi05_aloha_pen_uncap_lora",
    model=pi0_config.Pi0Config(
        pi05=True,
        paligemma_variant="gemma_2b_lora",
        action_expert_variant="gemma_300m_lora",
    ),
    ...
    batch_size=4,
    freeze_filter=pi0_config.Pi0Config(
        pi05=True,
        paligemma_variant="gemma_2b_lora",
        action_expert_variant="gemma_300m_lora",
    ).get_freeze_filter(),
    ema_decay=None,
)
```

`paligemma_variant="gemma_2b_lora"` injects LoRA adapters (rank 16/32) into all
Gemma 2B layers; `freeze_filter` freezes everything else. Optimizer state drops
by an order of magnitude and HBM fits.

### Wall 2: NCC_ETUP002 (tuple custom call)

With LoRA cutting trainable params down to ~22 tensors, the next failure is:

```
[ERROR] [NCC_ETUP002] The compiler encountered a custom call that uses
unsupported tuple-typed operands. Custom calls require tensor operands,
not tuple-typed ones.
```

`jax.jit(init)(rng, partial_params)` lowers `partial_params` (22 tensors)
into a `tuple<tensor x 22>` operand on the `NeuronBoundaryMarker-Start`
custom call. Neuron rejects tuple operands.

#### Fix (`01-train-init-cpu-eager.patch`)

Drop the jit on `init` and run it CPU-eager, then ship the result with
`jax.device_put`:

```python
# before
train_state = jax.jit(
    init,
    donate_argnums=(1,),
    in_shardings=replicated_sharding,
    out_shardings=state_sharding,
)(init_rng, partial_params)

# after
cpu_dev = jax.devices("cpu")[0]
with jax.default_device(cpu_dev):
    train_state = init(init_rng, partial_params)
train_state = jax.device_put(train_state, state_sharding)
```

A nice side-effect: the
`A large amount of constants were captured during lowering (7.54 GB total)`
warning we saw at init time also goes away.

### Wall 3: NCC_ISPP027 (multi-operand reduce)

Now `ptrain_step` jits, but compile fails:

```
[ERROR] [NCC_ISPP027] Reduce operation with multiple operand tensors is not
supported. Encountered reduce operation with 2 operands.
Split multi-operand reduce into separate single-operand reduce operations.
```

There are several plausible suspects (`global_norm`, LayerNorm fast variance,
softmax). Dumping the HLO MLIR and reading the metadata pinpoints the culprit:

```
stablehlo.reduce(%1804, %1805, %1806, %5)
  metadata: jvp(vmap(jit(pixelwise)))/argmax/.../reduce
```

The `pixelwise` name plus `argmax` says it's `augmax.ColorJitter`'s HSV path.
`jnp.argmax` lowers to a 2-operand reduce (value + index) and Neuron does not
implement the multi-operand variant.

#### Fix (`02-disable-augmax.patch`)

Dead-code the augmax block in `preprocess_observation` with `if train and False:`.
We lose data augmentation for now (open question for full fine-tunes); for a
1-step smoke run on Pi0.5 LoRA it doesn't matter.

```python
# model.py
if train and False:  # PATCH_NEURON_NO_AUGMAX: HSV argmax triggers NCC_ISPP027
    image = image / 2.0 + 0.5
    transforms = [...]
    image = jax.vmap(augmax.Chain(*transforms))(sub_rngs, image)
```

The `import augmax` line stays, so the package still has to be installed.

### Wall 4: empty INTERNAL error inside HLOToTensorizer

augmax disabled, `NCC_ISPP027` is gone. New failure:

```
jaxlib._jax.XlaRuntimeError: INTERNAL: .
```

(message is literally a period). `log-neuron-cc.txt` shows
`HLOToTensorizer / runHlo2Tensorizer` raising `CompilerInvalidInputException`
that gets swallowed. Looking at the per-partition HLO histogram, partition 5
is wildly skewed:

| partition | HLO ops | shape |
|---|---:|---|
| 0 | 200 | VIT (convolution) |
| 1, 2 | 170 | action expert MLP |
| 3, 4 | 220 | another VIT branch |
| **5** | **2044** | **`xor 177`, `shift-right-logical 166`, `or 161`, `shift-left 160`, `add 361`** |

`xor / shift-* / or` is the Threefry-2x32 PRNG signature. Pi0.5's `compute_loss`
samples `time` with `jax.random.beta(time_rng, 1.5, 1, batch_shape)`, and Beta
is implemented via rejection sampling -- JAX calls Threefry many times.
Combined with the LLM's 18-layer `nn.scan`, partition 5 ends up with 2044 ops
and `HLOToTensorizer` blows up.

#### Fix (`03-beta-to-uniform.patch`)

Replace the Beta sample with uniform:

```python
# pi0.py: compute_loss
# before
time = jax.random.beta(time_rng, 1.5, 1, batch_shape) * 0.999 + 0.001
# after
time = jax.random.uniform(time_rng, batch_shape, minval=0.001, maxval=0.999)
```

Beta(1.5, 1) and uniform are not the same distribution, so a real fine-tune
should gate this behind an env var rather than always swap. This sample
prioritizes "1 step compiles and runs on Trainium2", so the swap is
unconditional here.

#### Defensive companion (`04-no-rng-split.patch`)

In `gemma.py` and `vit.py`, change
`nn.scan(split_rngs={"params": True, "dropout": True})` to
`{"params": True, "dropout": False}`. Even with dropout=0.0, `nn.scan` still
materializes rng splits in the graph. Disabling that on its own does not
eliminate the partition-5 explosion (Beta is the real cause), but it removes
a class of latent re-introduction risk.

## Reproduction

```bash
AWS_PROFILE=<your-profile> \
samples/openpi-pi05-lora-trn2/reproduce.sh \
  --region ap-southeast-4 \
  --use-capacity-block --slot openpi-pi05-lora \
  --watch
```

Look for

```
Step 0: grad_norm=0.4076, loss=0.0647, param_norm=1803.7698
```

in `bootstrap`'s output.

### Reproducibility check (2026-06-17)

We re-applied `patches/*.patch` to a **fresh clone** of openpi (`c23745b`)
and got byte-identical results:

| | Run 1 (in-place patched openpi) | Run 2 (fresh clone + `patches/*.patch`) |
|---|---|---|
| openpi base commit | `c23745b` | `c23745b` |
| Applied patches | working tree | `samples/openpi-pi05-lora-trn2/patches/*.patch` |
| `git diff HEAD \| sha256sum` | `8ade2a8e...` | `8ade2a8e...` (identical) |
| Step 0 loss | 0.0647 | 0.0647 |
| Step 0 grad_norm | 0.4076 | 0.4076 |
| Step 0 param_norm | 1803.7698 | 1803.7698 |
| 1-step time (cold compile + ckpt save) | 19:53 | n/a (cache warm) |
| 1-step time (warm cache) | n/a | ~80 s (37.5 s train + 43.6 s ckpt save) |

`patches/*.patch` is the source of truth; `reproduce.sh` and `bootstrap.sh`
are thin plumbing around `git apply`.

## Open questions

- **Augmax impact on policy**: a real fine-tune needs an A/B over policies
  trained with vs. without augmax. The current patch is fine for a smoke run.
- **Beta vs. uniform on convergence**: time scheduling matters for Flow
  Matching convergence; we should gate this behind
  `OPENPI_USE_BETA_TIME=1` and run a sweep.
- **Warm step breakdown**: the 37.5 s per step bundles ckpt save and CPU
  `embed_suffix`. The pure Neuron forward+backward should be a few seconds;
  worth a profile.
- **`use_fast_variance` watch**: we touched `flax/linen/normalization.py`
  during the investigation in case it was the multi-operand reduce source.
  It wasn't, but if a future flax pin re-enables `use_fast_variance=True` we
  may see `NCC_ISPP027` come back from a different angle.
