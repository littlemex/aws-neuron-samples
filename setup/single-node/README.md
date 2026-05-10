# Single-node Neuron workstation

This directory provisions a single EC2 instance running the AWS Neuron
multi-framework DLAMI (Ubuntu 24.04). On top of the DLAMI it installs and
configures:

- [code-server](https://github.com/coder/code-server) behind an nginx
  reverse proxy, so you can drive the instance from a browser tab that
  looks and feels like VS Code.
- Persistent `/home/coder`, `/work`, and Neuron NEFF compile cache on EFS,
  so state survives instance stop/start, Spot interruption, and outright
  replacement.
- A hardened security group with no ingress, so the instance is reachable
  only through AWS Systems Manager Session Manager and port forwarding.

The workflow is intended for interactive development: writing and
compiling Neuron kernels, running small training jobs, experimenting with
the Neuron SDK, or debugging distributed code locally before scaling it up
on ParallelCluster or HyperPod.

## Contents

```
single-node/
├── cdk/           AWS CDK TypeScript app (CloudFormation stack definition)
├── scripts/       deploy.sh, recover.sh, capacity-block helpers, SSM task runner
└── tasks/         JSON task definitions executed by scripts/run-tasks.sh
```

The separation is deliberate. The CDK app owns the shape of the stack
(security group, IAM role, launch template, EC2 instance, Secrets Manager
secret, outputs). The shell scripts drive the lifecycle around it -
deploy, setup, recover, tear down. The JSON tasks define what actually
runs on the instance after it boots, and are invoked over SSM Run Command
so they can be re-executed idempotently at any time.

## Architecture

```
  ┌──────────────────────────┐   aws ssm start-session
  │ your laptop              │   --document-name AWS-StartPortForwardingSession
  │                          │◄─────────────────────────────────┐
  │ browser -> localhost:80XX│                                  │
  └──────────────────────────┘                                  │
                                                                │
  ┌──────────────────────────────────────────────────┐          │
  │ EC2 instance (Neuron DLAMI, Ubuntu 24.04)        │          │
  │                                                  │          │
  │  nginx :80  ──►  code-server :8080               │          │
  │                                                  │          │
  │  /home/coder ─► /mnt/efs/<subpath>/home-coder    │◄───┐     │
  │  /work       ─► /mnt/efs/<subpath>/work          │◄───┤     │
  │  NEFF cache  ─► /mnt/local (NVMe) ──rsync──► EFS │◄───┤     │
  │                                                  │    │     │
  │  SG: no ingress, outbound unrestricted           │────┘     │
  └──────────────────────────────────────────────────┘          │
                      ▲                                         │
                      └─────── SSM Session Manager ─────────────┘
```

Everything in the EFS layer is shared across instances that point at the
same `--efs-subpath`. Put each instance on its own subpath if you want
clean separation; share a subpath if you want two instances to see each
other's `/home/coder` and `/work`.

## Prerequisites

1. **AWS account and region.** The account must be bootstrapped for CDK
   in the target region:

   ```bash
   npx cdk bootstrap aws://ACCOUNT_ID/REGION
   ```

2. **Node.js 18+** to install CDK dependencies.

3. **AWS CLI v2** with credentials for your target account and the
   **Session Manager Plugin** for port forwarding.

4. **An EFS file system in the target region** (optional but strongly
   recommended). The single-node tooling expects an existing EFS and
   opens NFS (2049/tcp) from this stack's security group to the mount
   target security group automatically. If you want to run without
   persistence, pass `--no-efs` to `deploy.sh`; you will lose state when
   the instance is replaced or a Spot interruption wipes the root volume.

   To create an EFS with a private mount target in the default VPC:

   ```bash
   aws efs create-file-system \
     --region REGION \
     --encrypted \
     --tags Key=Name,Value=neuron-workspace

   # Take note of the FileSystemId, then create a mount target in the
   # subnet you plan to launch your instance in:
   aws efs create-mount-target \
     --region REGION \
     --file-system-id fs-XXXXXXXX \
     --subnet-id subnet-XXXXXXXX \
     --security-groups sg-XXXXXXXX
   ```

   Add the resulting `fs-XXXXXXXX` to `cdk/config.json` under your region
   as `defaultEfsId`, or pass it per-invocation via `--efs-id`.

5. **Quota for the instance type.** Trn1, Trn2, and Inf2 instances are
   subject to service quotas that are often lower than the default EC2
   quota and may require a ticket to raise.

## Default behavior

By default the stack creates:

- A launch template and single EC2 instance of type `trn2.3xlarge`
  (override with `--instance-type`).
- A dedicated security group with **no ingress rules** and unrestricted
  outbound (so apt, pip, ECR, and the SSM agent can work).
- An IAM role with exactly two managed policies:
  `AmazonSSMManagedInstanceCore` and `CloudWatchAgentServerPolicy`. You
  should grant additional permissions explicitly for the workload you
  plan to run; do not attach `AdministratorAccess` unless you need it.
- A Secrets Manager secret holding an auto-generated code-server password.
- A gp3-encrypted 500 GB root volume (override with `--volume-size`).
- A Neuron DLAMI resolved at deploy time from the public SSM parameter
  `/aws/service/neuron/dlami/multi-framework/ubuntu-24.04/latest/image_id`.
  To use a different image, export
  `NEURON_AMI_SSM_PARAMETER=<parameter-name>` before running `deploy.sh`.

## Deploy

Pick a stack name that does not collide with anything you already have
in the account, and choose an EFS subpath. If you plan to run multiple
instances, give each one its own subpath; otherwise they will share
`/home/coder` state.

```bash
export AWS_REGION=us-west-2

bash scripts/deploy.sh \
    --stack-name neuron-ws \
    --instance-type trn2.3xlarge \
    --efs-subpath /neuron-workspace/main
```

`deploy.sh` runs these steps in order:

1. `cdk deploy` creates the CloudFormation stack.
2. Reads `SecurityGroupId` and `EfsId` from the stack outputs.
3. Authorizes NFS (2049/tcp) from the new instance SG on every mount
   target SG of the EFS, so mounts will succeed.
4. Waits for the SSM agent to come Online (typically 2-3 minutes).
5. Uploads `scripts/setup-persistence.sh` to the instance and invokes
   `tasks/code-server-setup.json` through SSM Run Command. This installs
   and configures code-server, nginx, persistent storage, and a set of
   VS Code extensions. Every task is idempotent; re-running the whole
   setup is safe.

The script prints the code-server password, the instance id, and the
exact port-forwarding command to run when it completes.

### Connect

In a separate terminal:

```bash
AWS_REGION=us-west-2 bash scripts/deploy.sh \
    --port-forward --stack-name neuron-ws -p 8080:80
```

Then open `http://localhost:8080` in your browser and log in with the
generated password. Multiple ports, for example for a TensorBoard on 6006
or a Jupyter process on 8888, can be forwarded in one invocation:

```bash
AWS_REGION=us-west-2 bash scripts/deploy.sh \
    --port-forward --stack-name neuron-ws \
    -p 8080:80,6006:6006,8888:8888
```

To open a plain SSM shell:

```bash
aws ssm start-session --target $(aws cloudformation describe-stacks \
    --stack-name neuron-ws --region us-west-2 \
    --query 'Stacks[0].Outputs[?OutputKey==`InstanceId`].OutputValue' \
    --output text) \
    --region us-west-2
```

### Inspect an existing stack

```bash
AWS_REGION=us-west-2 bash scripts/deploy.sh \
    --show-info --stack-name neuron-ws
```

Prints the instance id, public DNS (not reachable over the internet -
shown for information only), stack status, availability zone, and the
code-server password.

### Tear down

```bash
AWS_REGION=us-west-2 bash scripts/deploy.sh \
    --destroy --stack-name neuron-ws
```

This reverses the setup: it revokes the cross-SG NFS rule on the EFS
mount target, then runs `cdk destroy`. The EFS itself is not deleted -
data you wrote under `/home/coder` and `/work` persists and will be
visible to the next stack that uses the same `--efs-subpath`.

## Running multiple instances in parallel

Three instances, each with isolated state, sharing the same EFS:

```bash
export AWS_REGION=us-west-2

bash scripts/deploy.sh --stack-name neuron-a \
    --efs-subpath /neuron-workspace/a &
bash scripts/deploy.sh --stack-name neuron-b \
    --efs-subpath /neuron-workspace/b &
bash scripts/deploy.sh --stack-name neuron-c \
    --efs-subpath /neuron-workspace/c &
wait
```

Each instance gets its own security group, its own password, and its own
subdirectory on EFS. `deploy.sh` ensures the cross-SG NFS rule is created
for every new SG automatically.

To attach port-forwards to all three at once, run three `--port-forward`
commands in separate terminals with different local ports:

```bash
bash scripts/deploy.sh --port-forward --stack-name neuron-a -p 3000:80
bash scripts/deploy.sh --port-forward --stack-name neuron-b -p 3001:80
bash scripts/deploy.sh --port-forward --stack-name neuron-c -p 3002:80
```

## Capacity Blocks and Spot

Trn2 capacity is often reserved through
[Capacity Blocks for ML](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-capacity-blocks.html),
which in supported regions schedule a 24-168 hour block against a
specific AZ. Helpers in `scripts/manage-capacity-block.sh` cover search,
purchase, list, describe, cancel, and SSM Parameter Store read/write for
the reservation id and subnet so they can be picked up automatically by
`deploy.sh`.

```bash
# Search for offerings
bash scripts/manage-capacity-block.sh search \
    --instance-type trn2.3xlarge --duration 96

# Purchase a specific offering
bash scripts/manage-capacity-block.sh purchase \
    --offering-id cb-offering-XXXXXXX --start-time 2030-01-01T11:30:00Z

# Persist the reservation id + subnet id in SSM so deploy.sh picks them up
bash scripts/manage-capacity-block.sh save-params \
    --reservation-id cr-XXXXXXXX --subnet-id subnet-XXXXXXXX

# Deploy against the reservation
bash scripts/deploy.sh --use-capacity-block --stack-name neuron-cb
```

Two additional helpers are provided but intentionally opt-in:

- `scripts/watch-capacity-block.sh` polls the search API on an interval
  and fires an optional local hook (desktop notification, Slack webhook,
  etc.) when matching capacity shows up.
- `scripts/watch-and-buy-capacity-block.sh` goes a step further and will
  purchase automatically against tight constraints you provide. Auto
  purchase is a commitment; read the script and its `--help` output
  carefully before using it.

For Spot, pass `--use-spot`. Spot is mutually exclusive with Capacity
Block. `stop` interruption behavior (re-startable) requires persistent
Spot requests; `terminate` uses one-time. The CDK app handles the
combinations correctly so you can pick whichever matches your workload:

```bash
# Spot, terminate on interruption (ephemeral work)
bash scripts/deploy.sh --use-spot --spot-interruption-behavior terminate

# Spot, stop on interruption so work resumes from disk + EFS
bash scripts/deploy.sh --use-spot --spot-interruption-behavior stop
```

## Disaster recovery

`scripts/recover.sh` is a single-command recovery tool for when an
instance is stopped, replaced, or otherwise disconnected from its SSM
tunnel. It re-reads the CloudFormation stack outputs, starts the instance
if it is stopped, re-authorizes the EFS NFS rule if it is missing, and
runs the idempotent setup tasks again.

```bash
AWS_REGION=us-west-2 bash scripts/recover.sh --stack-name neuron-ws
```

## Choosing an AMI

The CDK stack resolves the AMI in this order:

1. `NEURON_AMI_ID=ami-xxxxxxxxxxxxxxxxx` - pin an exact AMI id. Highest
   priority, skips SSM resolution entirely. Use this if you copied an AMI
   into your region with `aws ec2 copy-image` (for example, a workshop
   image) and want the stack to boot from that specific id.
2. `NEURON_AMI_SSM_PARAMETER=<parameter-name>` - resolve at deploy time
   via a user-supplied SSM parameter. Useful for private or pre-release
   channels that your account has access to.
3. (default) the public GA Neuron multi-framework DLAMI for Ubuntu 24.04,
   defined in `cdk/config.json` per region.

```bash
# Example: pin a specific copy of a workshop AMI in sa-east-1
export NEURON_AMI_ID=ami-xxxxxxxxxxxxxxxxx
AWS_REGION=sa-east-1 bash scripts/deploy.sh --stack-name neuron-workshop

# Example: pick up a custom SSM parameter your account manages
export NEURON_AMI_SSM_PARAMETER=/my-org/neuron/dlami/preview/image_id
AWS_REGION=us-west-2 bash scripts/deploy.sh --stack-name neuron-preview
```

The repository does not ship any private or pre-release parameter names
or AMI ids.

## End-to-end example: workshop-style launch with a copied AMI and a Capacity Block

This section shows the full flow for a common workshop scenario where
the organizer publishes an AMI in one region, you copy it into a region
where you can reserve Capacity Blocks, purchase the reservation, and
launch the instance through this tooling. The steps below use
`sa-east-1` as the Capacity Block region, but any region that offers
Capacity Blocks for your instance type works the same way.

```bash
# 1. Copy the workshop AMI into your target region. This returns a new
#    AMI id in the destination region; use that for the rest of the flow.
aws ec2 copy-image \
  --source-image-id ami-SOURCE1234567890 \
  --source-region us-west-2 \
  --name workshop-ami-copy \
  --region sa-east-1

# 2. Discover Capacity Block offerings in the target region.
aws ec2 describe-capacity-block-offerings \
  --instance-type trn2.3xlarge \
  --instance-count 1 \
  --capacity-duration-hours 168 \
  --region sa-east-1

# 3. Pick an offering id from the response and purchase it. This returns
#    a CapacityReservationId (cr-xxxxxxxxxxxxxxxxx).
aws ec2 purchase-capacity-block \
  --capacity-block-offering-id <CapacityBlockOfferingId> \
  --instance-platform Linux/UNIX \
  --region sa-east-1

# 4. Persist the reservation id and a subnet id that is in the same AZ
#    into SSM Parameter Store so deploy.sh picks them up automatically.
bash scripts/manage-capacity-block.sh save-params \
  --reservation-id cr-xxxxxxxxxxxxxxxxx \
  --subnet-id subnet-xxxxxxxxxxxxxxxxx \
  -r sa-east-1

# 5. Wait for the Capacity Block to transition to 'active'. Until then,
#    run-instances will fail with InvalidCapacityReservationState.
aws ec2 describe-capacity-reservations \
  --filters Name=instance-type,Values=trn2.3xlarge \
  --region sa-east-1

# 6. Deploy. NEURON_AMI_ID pins the copied workshop AMI; the stack
#    automatically opens NFS on the EFS mount target for the new SG and
#    runs the SSM-driven setup tasks.
export AWS_REGION=sa-east-1
export NEURON_AMI_ID=ami-COPY1234567890
bash scripts/deploy.sh \
  --use-capacity-block \
  --stack-name neuron-workshop \
  --efs-id fs-xxxxxxxxxxxxxxxxx \
  --efs-subpath /neuron-workspace/workshop

# 7. Once deploy.sh prints "deploy complete", open a port forward and
#    browse to http://localhost:8080. See the 'Connect' section above.
bash scripts/deploy.sh --port-forward --stack-name neuron-workshop -p 8080:80
```

If the workshop AMI ships a preconfigured Python virtualenv (for example
`/home/ubuntu/nki_bootcamp_venv`), activate it from the code-server
terminal as usual. The code-server user created by this setup is `coder`,
but other users such as `ubuntu` remain available on the AMI.

## Limitations

- The CDK app assumes the default VPC exists in the target region. If
  your account uses a dedicated VPC, adapt `lib/torch-neuron-stack.ts` to
  look it up by tag or id.
- `recover.sh` and `deploy.sh` exchange state through SSM Parameter Store
  and CloudFormation stack outputs. If you manually mutate either, the
  tooling will happily use your modifications.
- The setup tasks install a curated set of VS Code extensions. Trim or
  extend them in `tasks/code-server-setup.json` task `15`.

## Troubleshooting

- **`mount.nfs4: Connection timed out`** in the setup log: the EFS mount
  target security group is not allowing NFS from the new instance's SG.
  `deploy.sh` is supposed to open this automatically; rerun it, or run
  the same `authorize-security-group-ingress` manually.
- **`Instances not in a valid state`** from the setup script: the SSM
  agent has not registered yet. Wait another minute and re-run
  `scripts/setup-code-server.sh` manually with `--start-from 00-setup-persistence`.
- **code-server returns 502** through port forward: nginx or code-server
  is not active. SSH in over SSM (`aws ssm start-session --target <id>`)
  and check `systemctl status nginx code-server@coder` and their logs.
- **Password not shown by `--show-info`**: the Secrets Manager ARN
  lookup uses the CloudFormation stack-name tag. Make sure you pass the
  same `--stack-name` as at deploy time.

## License

Released under the MIT-0 License (see repository `LICENSE`).
