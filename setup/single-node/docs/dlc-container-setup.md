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
It does not contain any image URIs, ECR account ids, or wheel paths; it
reads them all from the environment so the same script works against
the public Neuron DLC gallery, any private team repository your account
has access to, and custom images you build yourself.

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

`setup-neuron-dlc.sh` is driven by environment variables so that no
image URI, account id, or tag ever has to live in this repository.

| Variable | Required | Description |
|---|---|---|
| `NEURON_DLC_IMAGE_URI` | yes | Full ECR image URI including tag. Example: `123456789012.dkr.ecr.us-east-1.amazonaws.com/my-repo:tag` |
| `NEURON_DLC_REGION` | no | Region of the ECR repository. Derived from the URI if unset. |
| `NEURON_DLC_WORKSPACE_DIR` | no | Host directory to extract `/workspace` into. Default `$HOME/neuron-dlc-workspace`. |
| `NEURON_DLC_VENV_DIR` | no | Host path for the Python virtualenv. Default `$HOME/neuron-dlc-venv`. |
| `NEURON_DLC_VENV_PYTHON` | no | Python binary used to build the venv. Default `python3`. |
| `NEURON_DLC_WHEEL_GLOBS` | no | Colon-separated list of wheel globs or package directories (relative to the extracted workspace) to `pip install`. Example: `wheels-a/*.whl:wheels-b/*.whl:pkg-c`. No default; set to match the layout of your specific image. |
| `NEURON_DLC_RUNTIME_DEB_DIR` | no | Subdirectory of the extracted workspace containing host runtime `.deb` packages. Default `runtime_artifacts`. |

The example file `.env.neuron-dlc.example` shows the shape of a local
environment file. Copy it to `.env.neuron-dlc`, fill in your own URI,
and source it before running the script. The `.gitignore` shipped with
this repository excludes `.env*` so your file stays local.

```bash
cp .env.neuron-dlc.example .env.neuron-dlc
$EDITOR .env.neuron-dlc
source .env.neuron-dlc
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

### Quick interactive poke

Pull the image and drop into a shell:

```bash
export NEURON_DLC_IMAGE_URI=...
bash scripts/setup-neuron-dlc.sh shell
```

### Run outside the container using a host-side venv

```bash
export NEURON_DLC_IMAGE_URI=...
export NEURON_DLC_WHEEL_GLOBS="wheels-a/*.whl:wheels-b/*.whl:pkg-c"
bash scripts/setup-neuron-dlc.sh venv
source $HOME/neuron-dlc-venv/bin/activate
python -c "import torch; print(torch.__version__)"
```

### Upgrade the on-host Neuron runtime from a DLC

Useful when the DLAMI has a GA runtime but your DLC ships a
pre-release runtime that the container depends on.

```bash
export NEURON_DLC_IMAGE_URI=...
bash scripts/setup-neuron-dlc.sh runtime
# `neuron-ls` will now reflect the upgraded runtime.
```

### All in one

```bash
export NEURON_DLC_IMAGE_URI=...
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
