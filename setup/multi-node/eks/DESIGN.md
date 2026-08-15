# Design: Neuron vLLM serving on EKS (multi-node/eks)

## Goal

Serve arbitrary vLLM-supported models on AWS Trainium (`trn2`) NeuronCores on an
**existing** EKS cluster, driven by a single `up.sh <model>` command. Adding a new
model is a matter of dropping a preset file under `models/`; no template edits.

Two topologies are covered:

- **single-node** — one `trn2.3xlarge` chip, tensor-parallel across its NeuronCores.
  This is the primary, verified path.
- **multi-node** — several `trn2.3xlarge` chips, tensor/pipeline-parallel across nodes
  over EFA. This is **experimental** (see "Multi-node status" below).

## What this shape assumes (and does not provision)

This shape does **not** create a cluster. It assumes an EKS cluster stood up by
[`distributed-ai/infra/eks`](https://github.com/littlemex/distributed-ai/tree/main/infra/eks),
which provides the pieces a serving workload needs:

| Provided by `infra/eks` | How this shape consumes it |
|---|---|
| Karpenter Neuron `NodePool`/`EC2NodeClass` (one per `accelerator_pools` key) | `nodeSelector: { node-role: <pool> }` |
| Node taints `aws.amazon.com/neuron`, `vpc.amazonaws.com/efa`, `capacity-reservation` | matching tolerations |
| `neuron-helm-chart` device plugin (advertises `aws.amazon.com/neuron`) | `resources` request/limit |
| `aws-efa-k8s-device-plugin` (advertises `vpc.amazonaws.com/efa`) | `resources` request/limit when `efaCount>0` |
| Static RWX PVs (`openzfs-shared` / `fsx-training` / `efs-neuron-workspace`) | a `PersistentVolumeClaim` bound by `volumeName` for the NEFF/weights cache |

Discover the live values instead of hardcoding them:

```bash
kubectl get nodes -l node-role=$POOL -o jsonpath="{.items[0].status.allocatable['aws\.amazon\.com/neuron']}"
kubectl get nodes -l node-role=$POOL -o jsonpath="{.items[0].status.allocatable['vpc\.amazonaws\.com/efa']}"
```

## The serving contract (single-node)

Derived from the infra's own `charts/experiments/templates/neuron-serving-vllm.yaml`
and the operational notes in `infra/eks/docs/feedback-neuron-serving-cache-pvc.md`:

- `Deployment` (replicas 1) + `Service`, one whole `trn2` chip per pod.
- `nodeSelector: { node-role: <pool> }`; tolerate `aws.amazon.com/neuron`,
  `vpc.amazonaws.com/efa`, `capacity-reservation` (`Exists:NoSchedule`).
- `resources`: `aws.amazon.com/neuron: "<neuronDevices>"` in both requests and limits;
  `vpc.amazonaws.com/efa: "<efaCount>"` only when `efaCount > 0`. **No hugepages** on a
  provisioning-triggering pod (Karpenter does not size new nodes against them).
- Size `memory` for the **compile-time** peak, not just steady-state inference — cold
  NEFF tracing of a large model can OOM the kubelet. `VLLM_NEURON_PARALLEL_TRACE_WORKERS=1`
  trades compile speed for peak RAM on small-RAM instances.
- Persist compiled NEFF + downloaded weights on an RWX PV so a Karpenter node swap or a
  Capacity Block expiry does not force a full recompile.
- `NEURON_SKIP_EFA_AFFINITY=1` on single-EFA-card instances (e.g. `trn2.3xlarge`): the
  Neuron EFA-affinity probe expects a co-located EFA under each NeuronCore's PCI path,
  which only holds on multi-card instances like `trn2.48xlarge`. The affinity is a
  CPU-locality optimization, not a correctness requirement.
- Readiness probe on `/health` with a long `initialDelaySeconds` (first boot compiles
  the model, which takes many minutes).

## Why a thin Helm chart

The infra's `charts/experiments` is a broad chart covering training probes, DDP, and
serving behind ten toggles. This shape ships a **small, serving-only** chart
(`chart/`) so a model preset maps directly to `--set` values and `up.sh` stays a
one-liner. It targets the same node/taint/PV contract, so it is portable to any cluster
that satisfies the table above; it does not depend on the infra chart's values API.

## Model presets

`models/<name>.yaml` is a plain values file consumed by `up.sh`. It carries the model id,
tensor-parallel size, sequence length, dtype, any extra vLLM args, and per-model env
(e.g. `trust_remote_code` for models with custom code). Serving a new model is:

```bash
./up.sh qwen3-vl            # uses models/qwen3-vl.yaml
./up.sh nemotron-h --pool trn2 --namespace serving
```

## Storage & multi-tenancy

The NEFF/weights cache is RWX. How it scales to many users depends on how the PV is provisioned:

- **Static PV (single-tenant).** An infra static PV (`openzfs-shared`, `fsx-training`) binds to
  exactly one PVC (1:1, a Kubernetes invariant). That one PVC can still be mounted by **many pods
  concurrently** (RWX), so several serving pods in one namespace can share the cache (use per-model
  subpaths). It cannot be shared across namespaces, and a second namespace cannot claim the same
  static PV.
- **Dynamic provisioning (multi-tenant).** With a dynamic StorageClass, every PVC provisions its
  own volume, so the 1:1 limit disappears. For a shared cache the right tool is **EFS access points**
  (`provisioningMode=efs-ap`): each PVC — in any namespace — gets its own isolated access point
  (own subdirectory + POSIX uid/gid) on one shared EFS filesystem. This was verified on a real
  cluster: two PVCs in two namespaces via an `efs-sc` each provisioned a distinct access point
  (`/dynamic/pvc-<uid-a>` and `/dynamic/pvc-<uid-b>`) on one EFS, and a pod mounted its access point
  RWX and read/wrote its own isolated directory.

  `up.sh <model> --storage-class efs-sc` selects this path (the chart leaves `volumeName` empty and
  provisions per-deployment). Create the class once (owner supplies the EFS id):

  ```yaml
  apiVersion: storage.k8s.io/v1
  kind: StorageClass
  metadata: { name: efs-sc }
  provisioner: efs.csi.aws.com
  parameters: { provisioningMode: efs-ap, fileSystemId: fs-XXXX, directoryPerms: "700", gidRangeStart: "1000", gidRangeEnd: "2000", basePath: "/dynamic" }
  ```

- **FSx Lustre is a poor fit for a shared multi-tenant cache.** It cannot sub-divide an existing
  filesystem per PVC (only whole-filesystem static binding, or a brand-new filesystem per dynamic
  PVC). It is also finicky to mount: on the verified cluster the client modules were loaded and the
  MGS was reachable, yet the mount returned `rc=-22` with `client profile '<mountname>-client' could
  not be read from the MGS` — an FSx-filesystem / LNet-level condition (security-group reachability
  to the Lustre ENIs or filesystem state), independent of this template. Prefer EFS (access points)
  or FSx OpenZFS (NFS) for the cache; they mount over NFS and avoid the Lustre client entirely.

**Recommendation.** For a single team, a static RWX PV is fine. For many users/namespaces, use a
dynamic EFS access-point StorageClass (`--storage-class efs-sc`) so each tenant gets an isolated,
self-service cache on one filesystem.

## Multi-node status (experimental)

`infra/eks` provides **no multi-node serving primitive** — no LeaderWorkerSet, no Ray
operator, no serving-flavored TrainJob runtime. Multi-node serving must therefore be
self-assembled: N pods + a headless `Service` + an app-level rendezvous (the pattern the
infra's `vllm-ray.yaml` uses for GPU pipeline-parallel). The `serving-multinode.yaml`
template implements that shape for Neuron, but **Neuron multi-node serving over EFA is
not verified** in this repo or upstream infra (the infra's own notes call it "untested —
no CB available to verify at review time"). Treat it as a starting point, not a
production-ready path, until it has a real two-node EFA run behind it. The single-node
path is the one to reach for first; a `trn2.3xlarge` chip already holds a 30B-A3B model
at TP=4.

## Not in scope

- Cluster/nodepool provisioning (that is `infra/eks`).
- Autoscaling / request routing / a gateway (single `Service` per model here).
- Continuous batching correctness for models with recurrent state (model-dependent).
