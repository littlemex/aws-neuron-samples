# Neuron vLLM serving on EKS

Serve vLLM-supported models on AWS Trainium (`trn2`) NeuronCores on an **existing** EKS
cluster, with a single command:

```bash
./up.sh qwen3-vl --namespace serving
```

Adding a model is a matter of dropping a preset under [`models/`](models/) — no template
edits. See [`DESIGN.md`](DESIGN.md) for the contract and the rationale.

The single-node path is verified end-to-end. On one `trn2.3xlarge` (TP=4):

- `./up.sh qwen3-vl` served `Qwen/Qwen3-VL-8B-Instruct` (stock image) — `"The capital of France
  is"` → `" Paris. The capital of Germany is Berlin..."`.
- `./up.sh nemotron-h` served `nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B-BF16` by installing the
  NemotronH PR into the plugin at startup (see below) — `"The capital of France is"` → `" Paris"`,
  `"2 + 2 ="` → `" 4"`, `"日本の首都は"` → `"東京"`.

## Prerequisites

This shape does not create a cluster. It assumes an EKS cluster provisioned by
[`distributed-ai/infra/eks`](https://github.com/littlemex/distributed-ai/tree/main/infra/eks),
which supplies the Karpenter Neuron node pools, the Neuron and EFA device plugins, the node
taints, and the static RWX PVs this shape's workloads schedule against. You also need `helm`
and `kubectl` (pointed at that cluster) locally.

Confirm the cluster exposes a Neuron pool and note its `node-role`:

```bash
kubectl get nodes -L node-role -L node.kubernetes.io/instance-type | grep trn2
```

## Contents

```
multi-node/eks/
├── up.sh          one-shot deploy: render chart with a model preset + kubectl apply + wait
├── down.sh        tear down (optionally keep the NEFF/weights cache PVC)
├── chart/         thin Helm chart (single-node and multinode serving templates + cache PVC)
├── models/        model presets (qwen3-vl, llama3.1-8b, nemotron-h, ...)
└── DESIGN.md      the infra/eks serving contract and design decisions
```

## Usage

```bash
# Single-node (one trn2.3xlarge chip, tensor-parallel across its NeuronCores):
./up.sh llama3.1-8b --pool trn2 --namespace serving

# Preview the rendered manifest without applying:
./up.sh qwen3-vl --dry-run

# Bind the cache to a specific infra static PV:
./up.sh qwen3-vl --volume fsx-training

# Tear down (keep the compiled-NEFF cache for a fast restart):
./down.sh qwen3-vl --namespace serving --keep-cache
```

Once ready:

```bash
kubectl -n serving port-forward svc/qwen3-vl 8000:8000
curl localhost:8000/v1/models
curl localhost:8000/v1/completions -H 'content-type: application/json' \
  -d '{"model":"qwen3-vl","prompt":"The capital of France is","max_tokens":8}'
```

## Gated models

For a gated checkpoint (e.g. Llama), create the token Secret in the serving namespace and
reference it from the preset (`hfTokenSecret`):

```bash
kubectl -n serving create secret generic hf-token --from-literal=token=hf_xxxxx
```

## Serving a model that isn't in the stock image yet

Some models ship in a plugin PR before they land in a released image (NemotronH is one). A preset
can install such a model into the plugin at pod startup by setting a `plugin` block:

```yaml
plugin:
  install: true
  repo: littlemex/vllm-neuron      # GitHub owner/repo of the fork carrying the model
  ref: feat/nemotron-h             # branch or tag to fetch
  modelDir: nemotron_h             # directory under vllm_neuron/model/
  registerClass: NemotronHForCausalLM
```

The container fetches that branch's tarball, copies the model package into the installed
`vllm_neuron` plugin, and registers the class before starting the server (see `models/nemotron-h.yaml`).
This runs on the stock image — no rebuild. For production, build an image with the plugin baked in
and set `image:` instead.

## Multi-node (experimental)

```bash
./up.sh <preset> --nodes 2
```

renders the multinode template (N pods + a headless Service + a Ray rendezvous over EFA).
**Neuron multi-node serving over EFA is not verified** — see the "Multi-node status" section
of [`DESIGN.md`](DESIGN.md). Reach for single-node first: a `trn2.3xlarge` chip already holds a
30B-A3B model at TP=4.

## First boot is slow

The first `up.sh` for a model compiles it to NEFF, which takes many minutes (the readiness
probe allows for this). The compiled artifacts and downloaded weights persist on the cache PVC,
so a subsequent `up.sh` for the same model on the same PV skips the cold compile.
