# setup/

This directory hosts deployment shapes for AWS Neuron development and
training workloads. Each shape provisions a different level of infrastructure
and is independently usable.

## Available shapes

| Shape | Status | Description |
|---|---|---|
| [`single-node/`](single-node/) | **Available** | A single EC2 Neuron DLAMI instance fronted by code-server, with persistent storage on EFS and SSM-only network access. Best for interactive development, kernel work, and small fine-tuning jobs. |
| [`multi-node/eks/`](multi-node/eks/) | **Available** | vLLM serving on Trainium NeuronCores on an existing EKS cluster (provisioned by `distributed-ai/infra/eks`). One `up.sh <model>` per model; add a model by dropping a preset. Single-node tensor-parallel is verified; multi-node over EFA is experimental. |
| `parallelcluster/` | Planned | AWS ParallelCluster-based multi-node setup for distributed training on Trn1/Trn2. |
| `hyperpod/` | Planned | SageMaker HyperPod-based cluster for resilient long-running training jobs. |

## What lives here vs elsewhere

The three shapes above intentionally duplicate the pieces that differ
between them (CDK apps, cluster definitions, bootstrap scripts) rather
than pretending they share more than they do. Truly shared utilities
(for example, a generic SSM-driven task runner, Neuron NEFF cache
configuration snippets, or EFS mount helpers) will move into a
`setup/common/` directory once a second shape lands and demands the same
functionality. This keeps each shape readable in isolation and avoids
premature abstractions that do not survive contact with the second use
case.

## Start here

If you are looking for the fastest way to get hands-on with Neuron on a
single instance, read [`single-node/README.md`](single-node/README.md).
It covers the end-to-end flow from `cdk bootstrap` to a browser tab
pointing at code-server over an SSM tunnel.
