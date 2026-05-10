# Running a Neuron Deep Learning Container (DLC) on a Trn / Inf instance

This document describes how to run a Neuron Deep Learning Container
(DLC) pulled from an Amazon ECR repository on an EC2 instance backed
by AWS Trainium or Inferentia.

It is the second supported workflow in this repository. For interactive
development against the bundled Neuron SDK that ships with the DLAMI,
see the top-level [`README.md`](../README.md) and run `deploy.sh`. Use
the DLC workflow instead when you need to pin an exact SDK build, run a
pre-release image distributed by a specific team, or reproduce a CI
pipeline's environment on a real instance.

The companion script is
[`scripts/setup-neuron-dlc.sh`](../scripts/setup-neuron-dlc.sh).

By default the script resolves to the public AWS Neuron DLC documented
at <https://awsdocs-neuron.readthedocs-hosted.com/en/latest/dlc/index.html>,
so it works out of the box on a vanilla AWS account with no additional
configuration. Every coordinate (account, repository, tag, region,
or a fully-specified URI) can be overridden by an environment variable,
so the same script also works against any private team repository your
account has access to, or a custom image you built yourself.

## Prerequisites

1. A running EC2 instance with Neuron hardware visible (`neuron-ls`).
2. Docker installed and the login user added to the `docker` group:

   ```bash
   sudo apt-get update && sudo apt-get install -y docker.io
   sudo usermod -aG docker $USER
   newgrp docker     # or log out and log back in
   ```

3. AWS CLI v2 with credentials that allow `ecr:GetAuthorizationToken`
   and `ecr:BatchGetImage` against the ECR repository that hosts the
   image you intend to pull.

## Configuration via environment variables

`setup-neuron-dlc.sh` composes the target image URI from four variables,
each with a sensible public default:

| Variable | Default | Description |
|---|---|---|
| `NEURON_DLC_ACCOUNT` | `763104351884` | ECR account id. The default is the public AWS Neuron DLC account. |
| `NEURON_DLC_REPO` | `pytorch-training-neuronx` | ECR repository name. Change for `pytorch-inference-neuronx` or any other repo. |
| `NEURON_DLC_TAG` | latest GA tag recorded in the script | ECR image tag. Verify against the [DLC release notes](https://github.com/aws-neuron/deep-learning-containers/releases) before pinning a new value. |
| `NEURON_DLC_REGION` | IMDSv2 → `AWS_REGION` → `us-west-2` | Region of the ECR repository. |

If you need to bypass the composition entirely (for example a private
image at a URI that does not follow the default pattern), set:

| Variable | Description |
|---|---|
| `NEURON_DLC_IMAGE_URI` | Full ECR image URI including tag. When set, takes precedence over the four variables above. |

Extraction and venv options:

| Variable | Default | Description |
|---|---|---|
| `NEURON_DLC_WORKSPACE_DIR` | `$HOME/neuron-dlc-workspace` | Host directory where `/workspace` from the image is extracted. |
| `NEURON_DLC_VENV_DIR` | `$HOME/neuron-dlc-venv` | Host path for the Python virtualenv. |
| `NEURON_DLC_VENV_PYTHON` | `python3` | Python binary used to build the venv. |
| `NEURON_DLC_WHEEL_GLOBS` | (empty) | Colon-separated list of wheel globs or package directories (relative to the extracted workspace) to `pip install`. Example: `wheels-a/*.whl:wheels-b/*.whl:pkg-c`. Set to match the layout of your image. |
| `NEURON_DLC_RUNTIME_DEB_DIR` | `runtime_artifacts` | Subdirectory of the extracted workspace containing host runtime `.deb` packages. |

You can either export these directly, or keep a local env file outside
the repository tree. An annotated template lives at
[`dlc.env.example`](./dlc.env.example). The `.gitignore` shipped with
this repository excludes `.env*` so your personal copy stays local.

```bash
cp setup/single-node/docs/dlc.env.example ~/.config/neuron-dlc.env
$EDITOR ~/.config/neuron-dlc.env
set -a; source ~/.config/neuron-dlc.env; set +a
```

## Modes

```bash
bash scripts/setup-neuron-dlc.sh {login|pull|shell|extract|venv|runtime|all}
```

| Mode | Purpose |
|---|---|
| `login` | Log Docker in to ECR. Useful as a standalone check. |
| `pull` | `docker pull` the configured image. |
| `shell` | Pull and open an interactive privileged shell inside the container. The extracted workspace on the host is mounted at `/workspace-host`. |
| `extract` | Pull and copy the image's `/workspace` directory onto the host at `NEURON_DLC_WORKSPACE_DIR`. Non-destructive: skips if the target is already populated. |
| `venv` | Run `extract`, then create `NEURON_DLC_VENV_DIR` and `pip install` each entry in `NEURON_DLC_WHEEL_GLOBS`. |
| `runtime` | Run `extract`, then `sudo dpkg -i` every `.deb` under `NEURON_DLC_RUNTIME_DEB_DIR`. Use this when the DLC ships a runtime newer than what the DLAMI has on the host. |
| `all` | `extract` + `runtime` + `venv`. |

## Typical flows

### Pull the public DLC with no extra configuration

The default environment points at the public AWS Neuron DLC, so:

```bash
bash scripts/setup-neuron-dlc.sh pull
```

…just works. The image is tagged and pinned in the script; inspect
`PUBLIC_DEFAULT_TAG` at the top of `setup-neuron-dlc.sh` to see the
exact version you will receive.

### Quick interactive poke

Pull the image and drop into a shell:

```bash
bash scripts/setup-neuron-dlc.sh shell
```

### Pin a different DLC tag

```bash
export NEURON_DLC_TAG=<newer-tag-from-release-notes>
bash scripts/setup-neuron-dlc.sh pull
```

### Use an inference-only image

```bash
export NEURON_DLC_REPO=pytorch-inference-neuronx
bash scripts/setup-neuron-dlc.sh shell
```

### Pull from a private or pre-release repository

```bash
export NEURON_DLC_IMAGE_URI=<full-private-uri>
bash scripts/setup-neuron-dlc.sh shell
```

### Run outside the container using a host-side venv

```bash
export NEURON_DLC_WHEEL_GLOBS="wheels-a/*.whl:wheels-b/*.whl:pkg-c"
bash scripts/setup-neuron-dlc.sh venv
source $HOME/neuron-dlc-venv/bin/activate
python -c "import torch; print(torch.__version__)"
```

### Upgrade the on-host Neuron runtime from a DLC

Useful when the DLAMI has a GA runtime but the DLC you are pulling
ships a newer runtime that the container depends on.

```bash
bash scripts/setup-neuron-dlc.sh runtime
# `neuron-ls` will now reflect the upgraded runtime.
```

### All in one

```bash
export NEURON_DLC_WHEEL_GLOBS="wheels-a/*.whl:wheels-b/*.whl:pkg-c"
bash scripts/setup-neuron-dlc.sh all
```

## Safety

- The script reads configuration only from the process environment. It
  never writes the URI, tag, or any credential into a file under the
  repository tree.
- The `dpkg -i` step in `runtime` mode needs `sudo`. Review the
  contents of `NEURON_DLC_RUNTIME_DEB_DIR` before running it.
- When you are done, `docker image rm $NEURON_DLC_IMAGE_URI` and
  `rm -rf $NEURON_DLC_WORKSPACE_DIR $NEURON_DLC_VENV_DIR` will clean
  the host back to its pre-run state.

## Troubleshooting

- **`ECR login` fails with `AuthFailure`**: your AWS credentials do
  not have `ecr:GetAuthorizationToken` against the target account, or
  `NEURON_DLC_REGION` points to the wrong region.
- **`no basic auth credentials` on `docker pull`**: login succeeded
  against one registry but the image URI points at a different one.
  Confirm that the registry host in `NEURON_DLC_IMAGE_URI` matches the
  account you logged in to.
- **`extract` reports "Workspace dir already populated"**: the script
  is refusing to overwrite an existing workspace. Remove or rename
  `NEURON_DLC_WORKSPACE_DIR` if you want a fresh copy.
- **`dpkg -i` fails with missing dependencies**: the script falls back
  to `apt-get -f install`. If that also fails you probably do not have
  the kernel headers for the running kernel; `sudo apt-get install
  linux-headers-$(uname -r)` usually resolves it.
