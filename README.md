# aws-neuron-samples

Reference infrastructure and tooling for building interactive development
environments on [AWS Neuron](https://awsdocs-neuron.readthedocs-hosted.com/)
accelerators (Trainium and Inferentia). The goal is to give researchers and
engineers a reproducible path from a fresh AWS account to a fully
configured, persistent workstation running on Trainium or Inferentia, with
no manual cluster plumbing.

The initial release focuses on the single-node workflow, which is also the
quickest way to evaluate Neuron SDK features interactively, iterate on
Neuron kernels, or attach a VS Code-in-the-browser session to a long-running
compilation or fine-tuning job. Additional setups for AWS ParallelCluster
and SageMaker HyperPod are planned and will share the same conventions.

## Repository layout

```
.
├── LICENSE
├── CONTRIBUTING.md
├── README.md                    You are here.
└── setup/
    ├── README.md                Overview of supported deployment shapes.
    └── single-node/             Single EC2 Neuron DLAMI + code-server (this release).
        ├── README.md
        ├── cdk/                 AWS CDK (TypeScript) application.
        ├── scripts/             Deploy, recover, capacity-block tooling.
        └── tasks/               JSON task definitions executed via SSM Run Command.
```

Each deployment shape under `setup/` is self-contained. Code that is
genuinely shared across shapes will move into a top-level `setup/common/`
directory once the ParallelCluster and HyperPod variants land, rather than
being prematurely generalised.

## Quick start (single node)

From a fresh shell with AWS credentials exported for your target account,
and a region that offers the Neuron instance you want:

```bash
cd setup/single-node

# One-time: install CDK dependencies
(cd cdk && npm install)

# Deploy a trn2.3xlarge with code-server, on-demand, in us-west-2
AWS_REGION=us-west-2 bash scripts/deploy.sh \
    --stack-name neuron-ws \
    --instance-type trn2.3xlarge

# When finished, tear everything down
AWS_REGION=us-west-2 bash scripts/deploy.sh \
    --stack-name neuron-ws --destroy
```

The full walkthrough, including EFS setup, Capacity Block reservations,
Spot usage, and multi-stack hygiene, is documented in
[`setup/single-node/README.md`](setup/single-node/README.md).

## Design principles

- **Reproducibility over convenience.** Everything that affects a running
  instance is either CDK (infrastructure) or an idempotent SSM Run Command
  task (configuration). There is intentionally no hand-edited state on the
  instance that a second run of the tooling would not reproduce.
- **No public HTTP endpoints.** The instance security group has no ingress
  rules. Access to code-server is through SSM Session Manager port
  forwarding exclusively. This avoids exposing an unauthenticated HTTP
  surface on a public IP, which is something public-endpoint security
  scanners reliably flag.
- **Persistence across Spot interruptions.** When the instance is stopped
  or replaced, `/home/coder`, `/work`, and the Neuron NEFF compile cache
  are restored from EFS on the next start. The NVMe instance store is
  treated as a cache tier, not storage of record.
- **Public defaults, with an opt-in for pre-release AMIs.** By default the
  tooling resolves the latest GA Neuron multi-framework DLAMI for Ubuntu
  24.04 via the public SSM parameter
  `/aws/service/neuron/dlami/multi-framework/ubuntu-24.04/latest/image_id`.
  To use an alternative image (custom AMI, private or beta DLAMI), export
  `NEURON_AMI_SSM_PARAMETER=<parameter-name>` before running `cdk deploy`.
  No non-GA SSM parameter names are hard-coded into the repository.
- **Least surprise IAM.** The instance role attaches
  `AmazonSSMManagedInstanceCore` and `CloudWatchAgentServerPolicy` and
  nothing else. Extend it explicitly for your workload; do not add
  `AdministratorAccess` unless you need it.

## Requirements

- Node.js 18 or newer, `npm`, and the AWS CDK bootstrap in your target
  account and region (`npx cdk bootstrap aws://ACCOUNT_ID/REGION`).
- AWS CLI v2 with credentials that can create the resources in
  `setup/single-node/cdk/lib/torch-neuron-stack.ts` (CloudFormation, EC2,
  IAM, Secrets Manager, SSM).
- Session Manager Plugin for `aws ssm start-session`
  ([install guide](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)).
- An EFS file system in the target region and AZ, or pass `--no-efs` to
  run without persistent storage. The single-node setup README explains
  how to preprovision one.

## Related reading

- [Neuron SDK documentation](https://awsdocs-neuron.readthedocs-hosted.com/)
- [Trn1, Trn2, Inf1, Inf2 instance documentation](https://aws.amazon.com/machine-learning/trainium/)
- [Capacity Blocks for ML](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-blocks.html)
- [AWS Session Manager port forwarding](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-sessions-start.html#sessions-start-port-forwarding)

## Security

Security issues should be reported through the AWS vulnerability reporting
process at <https://aws.amazon.com/security/vulnerability-reporting/> rather
than via public issues.

## License

Released under the [MIT-0](LICENSE) license.
