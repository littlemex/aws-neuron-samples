#!/bin/bash
# setup-neuron-dlc.sh - pull a Neuron Deep Learning Container (DLC) from ECR
# and prepare a ready-to-use environment on a Trn / Inf EC2 instance.
#
# Why this exists
# ---------------
# Two workflows are common on Neuron instances:
#   (1) Run the DLAMI directly and use the bundled Neuron SDK.
#   (2) Run a Neuron DLC image pulled from ECR. This is how pre-release
#       or team-vended images are distributed, and how CI pipelines pin
#       an exact SDK build.
#
# deploy.sh in this repository provisions option (1). This script covers
# option (2) for cases where you want to (a) run a specific DLC image
# interactively, (b) extract its wheels into a venv, or (c) update the
# on-host Neuron runtime from the DLC's .deb artifacts.
#
# By default the script resolves to the public AWS Neuron DLC so it
# works out of the box on a vanilla AWS account. The default image is
# composed from the PUBLIC_DEFAULT_* constants below. Every component
# (account, repo, tag, region) can be overridden by the environment
# variables documented in the "Configuration" section, and setting
# NEURON_DLC_IMAGE_URI replaces the composed URI entirely. This means
# the same script covers the public DLC gallery as well as any private
# or pre-release ECR repository your account has access to. No secret
# identifiers are required to ship with the repository.
#
# Configuration
# -------------
# Defaults resolve to the public AWS Neuron Deep Learning Container
# (documented at https://awsdocs-neuron.readthedocs-hosted.com/en/latest/dlc/index.html).
# Override any of the following environment variables to point the script at
# a different image (for example a private or pre-release build).
#
#   NEURON_DLC_IMAGE_URI     Full ECR image URI including tag. If set, takes
#                            precedence over the composed URI below.
#                            e.g. 123456789012.dkr.ecr.us-east-1.amazonaws.com/my-repo:tag
#
#   NEURON_DLC_ACCOUNT       ECR account id. Default: 763104351884 (public
#                            AWS DLC). Change when pulling from a private
#                            account.
#   NEURON_DLC_REPO          ECR repository name. Default:
#                            pytorch-training-neuronx. Alternatives include
#                            pytorch-inference-neuronx.
#   NEURON_DLC_TAG           Image tag. Default: the latest GA tag known
#                            at the time of writing (see PUBLIC_DEFAULT_TAG
#                            constant). Verify against
#                            https://github.com/aws-neuron/deep-learning-containers/releases
#                            before relying on it for production.
#   NEURON_DLC_REGION        Region of the ECR repository. If unset, it is
#                            resolved from IMDSv2 on the running EC2
#                            instance, then AWS_REGION, then us-west-2.
#
#   NEURON_DLC_WORKSPACE_DIR Host path to extract the image subtree into.
#                            Default: $HOME/neuron-dlc-workspace
# Source path inside the container image used by `extract`, `venv`, and
# `runtime` modes is controlled by the --extract-path CLI argument (see
# the argument parser below). When --extract-path is not given, extract
# looks for /workspace at the image root (the convention used by AWS's
# pre-release / bootcamp-style DLCs) and falls back to a no-op when it
# is missing. This keeps the script useful against arbitrary Neuron DLC
# layouts: `pull` and `shell` still work, and if you need to extract a
# specific subtree you pass it explicitly, for example:
#
#   bash setup-neuron-dlc.sh extract --extract-path /opt/aws_neuronx_venv_pytorch_2_9
#   NEURON_DLC_VENV_DIR      Host path to create a Python venv in.
#                            Default: $HOME/neuron-dlc-venv
#   NEURON_DLC_VENV_PYTHON   Python binary to build the venv with.
#                            Default: python3
#   NEURON_DLC_WHEEL_GLOBS   Colon-separated list of path globs, relative to
#                            the extracted /workspace, that point at wheel
#                            files or source directories to `pip install`.
#                            Example: "wheels-a/*.whl:wheels-b/*.whl:pkg-c"
#                            No default is provided; set this to match the
#                            layout of your specific DLC image.
#   NEURON_DLC_RUNTIME_DEB_DIR
#                            Directory inside the extracted /workspace that
#                            contains on-host runtime .deb packages. Default:
#                            runtime_artifacts
#
# Modes
# -----
# The first positional argument selects what to do:
#   login     Just authenticate Docker with ECR.
#   pull      Login, then docker pull the image.
#   shell     Login + pull + run the image interactively (privileged).
#   extract   Login + pull + copy /workspace from the image to
#             NEURON_DLC_WORKSPACE_DIR on the host. Non-destructive.
#   venv      extract + create NEURON_DLC_VENV_DIR and pip install the wheels
#             listed in NEURON_DLC_WHEEL_GLOBS.
#   runtime   extract + sudo dpkg -i the .deb files under
#             NEURON_DLC_RUNTIME_DEB_DIR. Use this if the DLC ships a runtime
#             newer than what the DLAMI has on host.
#   all       extract + venv + runtime.
#
# Example
# -------
#   export NEURON_DLC_IMAGE_URI=123456789012.dkr.ecr.us-west-2.amazonaws.com/my-repo:sha-abcdef
#   bash scripts/setup-neuron-dlc.sh venv
#   source $HOME/neuron-dlc-venv/bin/activate
#   python -c "import torch, neuronxcc; print('ok')"
#
# Safety
# ------
# The only identifiers baked into the repository are the well-known public
# DLC coordinates (account 763104351884, repo pytorch-training-neuronx,
# PUBLIC_DEFAULT_TAG above). Any non-default URI must be supplied through
# the environment at run time. The script never writes user-supplied URIs
# or credentials to files under the repository tree, so it is safe to run
# on a host that is later shared or cloned.

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()     { echo -e "${BLUE}[dlc]${NC} $*"; }
success() { echo -e "${GREEN}[dlc]${NC} $*"; }
warn()    { echo -e "${YELLOW}[dlc]${NC} $*" >&2; }
die()     { echo -e "${RED}[dlc]${NC} $*" >&2; exit 1; }

# ---- arguments --------------------------------------------------------
# Usage:
#   setup-neuron-dlc.sh MODE [--extract-path PATH]
#
# MODE is one of login|pull|shell|extract|venv|runtime|all. Options can
# appear before or after MODE. The only currently supported option is
# --extract-path, which pins the absolute path inside the image used by
# the `extract`, `venv`, and `runtime` modes. When it is not set,
# `extract` auto-detects a reasonable source directory by probing a
# list of common Neuron DLC layouts.
MODE=""
EXTRACT_PATH=""

print_usage() {
    cat <<'EOF' >&2
Usage: setup-neuron-dlc.sh MODE [--extract-path PATH]

MODE: login | pull | shell | extract | venv | runtime | all

Options:
  --extract-path PATH           Absolute path inside the container image to copy out
                                during `extract` (and consumed by `venv` / `runtime`).
                                When omitted, `extract` looks for /workspace at the
                                image root and uses it if present; otherwise it warns
                                and skips instead of failing. Pass the flag explicitly
                                for any other subtree, for example
                                `--extract-path /opt/aws_neuronx_venv_pytorch_2_9`.
  -h, --help                    Print this help and exit.

Image selection is controlled by environment variables. Defaults pull the latest GA AWS
Neuron DLC (pytorch-training-neuronx):

  NEURON_DLC_IMAGE_URI          Full ECR image URI including tag. If set, takes precedence
                                over the composed URI below.
  NEURON_DLC_ACCOUNT            ECR account id (default: 763104351884).
  NEURON_DLC_REPO               ECR repository (default: pytorch-training-neuronx).
  NEURON_DLC_TAG                Image tag (see PUBLIC_DEFAULT_TAG in this file).
  NEURON_DLC_REGION             ECR region (default: IMDSv2 -> AWS_REGION -> us-west-2).

Host-side paths:

  NEURON_DLC_WORKSPACE_DIR      Default: $HOME/neuron-dlc-workspace
  NEURON_DLC_VENV_DIR           Default: $HOME/neuron-dlc-venv
  NEURON_DLC_VENV_PYTHON        Default: python3
  NEURON_DLC_WHEEL_GLOBS        Colon-separated wheel globs (no default).
  NEURON_DLC_RUNTIME_DEB_DIR    Default: runtime_artifacts

See the header of this script for full documentation.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --extract-path)
            if [[ $# -lt 2 ]]; then
                die "--extract-path requires an argument"
            fi
            EXTRACT_PATH="$2"
            shift 2
            ;;
        --extract-path=*)
            EXTRACT_PATH="${1#--extract-path=}"
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        login|pull|shell|extract|venv|runtime|all)
            if [[ -n "$MODE" ]]; then
                die "multiple modes given: $MODE and $1"
            fi
            MODE="$1"
            shift
            ;;
        *)
            print_usage
            die "unknown argument: $1"
            ;;
    esac
done

if [[ -z "$MODE" ]]; then
    print_usage
    exit 1
fi

# ---- default image URI ----------------------------------------------
# The public AWS Neuron DLC account id is documented at
# https://awsdocs-neuron.readthedocs-hosted.com/en/latest/dlc/index.html
PUBLIC_DEFAULT_ACCOUNT="763104351884"
PUBLIC_DEFAULT_REPO="pytorch-training-neuronx"
# Latest GA tag known at the time of writing. Always verify against
# https://github.com/aws-neuron/deep-learning-containers/releases
# before relying on this in production.
PUBLIC_DEFAULT_TAG="2.9.0-neuronx-py312-sdk2.29.1-ubuntu24.04"

resolve_region() {
    if [[ -n "${NEURON_DLC_REGION:-}" ]]; then
        echo "$NEURON_DLC_REGION"
        return
    fi
    # Try IMDSv2 on the current EC2 instance.
    local token region
    token=$(curl -sSfX PUT http://169.254.169.254/latest/api/token \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null || true)
    if [[ -n "$token" ]]; then
        region=$(curl -sSf -H "X-aws-ec2-metadata-token: $token" \
            http://169.254.169.254/latest/meta-data/placement/region 2>/dev/null || true)
        if [[ -n "$region" ]]; then
            echo "$region"
            return
        fi
    fi
    echo "${AWS_REGION:-us-west-2}"
}

# If NEURON_DLC_IMAGE_URI is already set, honour it as-is. Otherwise compose
# one from NEURON_DLC_{ACCOUNT,REPO,TAG,REGION}, falling back to the public
# default for any that are unset.
if [[ -z "${NEURON_DLC_IMAGE_URI:-}" ]]; then
    NEURON_DLC_ACCOUNT="${NEURON_DLC_ACCOUNT:-$PUBLIC_DEFAULT_ACCOUNT}"
    NEURON_DLC_REPO="${NEURON_DLC_REPO:-$PUBLIC_DEFAULT_REPO}"
    NEURON_DLC_TAG="${NEURON_DLC_TAG:-$PUBLIC_DEFAULT_TAG}"
    NEURON_DLC_REGION="${NEURON_DLC_REGION:-$(resolve_region)}"
    NEURON_DLC_IMAGE_URI="${NEURON_DLC_ACCOUNT}.dkr.ecr.${NEURON_DLC_REGION}.amazonaws.com/${NEURON_DLC_REPO}:${NEURON_DLC_TAG}"
fi

# Parse ECR region out of URI if caller did not set NEURON_DLC_REGION.
if [[ -z "${NEURON_DLC_REGION:-}" ]]; then
    # URI shape: <acct>.dkr.ecr.<region>.amazonaws.com/<repo>:<tag>
    NEURON_DLC_REGION=$(echo "$NEURON_DLC_IMAGE_URI" | sed -nE 's|^[0-9]+\.dkr\.ecr\.([^.]+)\.amazonaws\.com/.*|\1|p')
    if [[ -z "$NEURON_DLC_REGION" ]]; then
        die "Could not derive region from NEURON_DLC_IMAGE_URI. Set NEURON_DLC_REGION explicitly."
    fi
fi

# Resolve HOME explicitly so defaults work even when invoked from a
# non-interactive context (SSM Run Command, cron, etc.) where HOME is
# sometimes unset.
if [[ -z "${HOME:-}" ]]; then
    HOME=$(getent passwd "$(id -un)" | cut -d: -f6)
fi
NEURON_DLC_WORKSPACE_DIR="${NEURON_DLC_WORKSPACE_DIR:-$HOME/neuron-dlc-workspace}"
NEURON_DLC_VENV_DIR="${NEURON_DLC_VENV_DIR:-$HOME/neuron-dlc-venv}"
NEURON_DLC_VENV_PYTHON="${NEURON_DLC_VENV_PYTHON:-python3}"
NEURON_DLC_RUNTIME_DEB_DIR="${NEURON_DLC_RUNTIME_DEB_DIR:-runtime_artifacts}"
NEURON_DLC_WHEEL_GLOBS="${NEURON_DLC_WHEEL_GLOBS:-}"

log "Image URI     : $NEURON_DLC_IMAGE_URI"
log "ECR region    : $NEURON_DLC_REGION"
log "Workspace dir : $NEURON_DLC_WORKSPACE_DIR"
log "Venv dir      : $NEURON_DLC_VENV_DIR"
log "Mode          : $MODE"

# ---- helpers ----------------------------------------------------------
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

ensure_docker() {
    need_cmd docker
    if ! docker info >/dev/null 2>&1; then
        die "Docker is not running or the current user cannot talk to the daemon. Add your user to the docker group or use sudo."
    fi
}

ecr_login() {
    ensure_docker
    need_cmd aws
    local registry
    registry=$(echo "$NEURON_DLC_IMAGE_URI" | cut -d/ -f1)
    log "ECR login against $registry"
    aws ecr get-login-password --region "$NEURON_DLC_REGION" \
        | docker login --username AWS --password-stdin "$registry" >/dev/null
    success "ECR login OK"
}

image_pull() {
    ecr_login
    log "docker pull $NEURON_DLC_IMAGE_URI"
    docker pull "$NEURON_DLC_IMAGE_URI"
    success "Pull complete"
}

image_id_of() {
    docker images --filter "reference=$NEURON_DLC_IMAGE_URI" --format '{{.ID}}' | head -1
}

do_extract() {
    image_pull
    local image_id
    image_id=$(image_id_of)
    [[ -n "$image_id" ]] || die "Could not find image id after pull"
    if [[ -d "$NEURON_DLC_WORKSPACE_DIR" ]] && [[ -n "$(ls -A "$NEURON_DLC_WORKSPACE_DIR" 2>/dev/null)" ]]; then
        warn "Workspace dir already populated: $NEURON_DLC_WORKSPACE_DIR"
        warn "Skipping extract. Remove or rename it to force a fresh extract."
        return 0
    fi

    local cname
    cname="dlc-extract-$$-$(date +%s)"
    log "Creating temporary container to inspect image ..."
    docker create --name "$cname" "$image_id" >/dev/null
    trap 'docker rm -f "'"$cname"'" >/dev/null 2>&1 || true' EXIT

    # Resolve the source path. Priority:
    #   1. explicit --extract-path from the CLI
    #   2. auto-detection against a short list of common Neuron DLC layouts
    # If neither yields an existing path inside the image we warn and
    # skip instead of failing, because a plain `docker pull` still works
    # and the user can fall back to `bash setup-neuron-dlc.sh shell`.
    local src_path=""
    if [[ -n "$EXTRACT_PATH" ]]; then
        if docker cp "$cname":"$EXTRACT_PATH" - >/dev/null 2>&1; then
            src_path="$EXTRACT_PATH"
        else
            warn "Requested --extract-path $EXTRACT_PATH not found in image"
            docker rm -f "$cname" >/dev/null 2>&1 || true
            trap - EXIT
            return 0
        fi
    else
        # No --extract-path given. Auto-detection across arbitrary DLC
        # layouts is unreliable (images differ widely in where they put
        # venvs, examples, and artifacts), so we only try the single
        # convention that AWS uses on pre-release / bootcamp-style DLCs:
        # /workspace at the image root. Everything else should be driven
        # explicitly by --extract-path PATH.
        if docker cp "$cname":/workspace - >/dev/null 2>&1; then
            src_path="/workspace"
            log "Auto-detected extract source: /workspace"
        fi
    fi

    if [[ -z "$src_path" ]]; then
        docker rm -f "$cname" >/dev/null 2>&1 || true
        trap - EXIT
        warn "No known extract source was found inside the image."
        warn "Most public Neuron DLCs do not ship a /workspace tree, so this is"
        warn "expected. To inspect the image interactively run:"
        warn "  bash $(basename "$0") shell"
        warn "Or re-run with an explicit path:"
        warn "  bash $(basename "$0") extract --extract-path /path/inside/image"
        return 0
    fi

    mkdir -p "$NEURON_DLC_WORKSPACE_DIR"
    log "Copying $src_path/. to $NEURON_DLC_WORKSPACE_DIR ..."
    docker cp "$cname":"${src_path%/}/." "$NEURON_DLC_WORKSPACE_DIR"/
    docker rm -f "$cname" >/dev/null
    trap - EXIT
    success "Extracted $src_path -> $NEURON_DLC_WORKSPACE_DIR"
    log "Top-level contents:"
    ls -1 "$NEURON_DLC_WORKSPACE_DIR" | sed 's/^/  /'
}

do_venv() {
    do_extract
    need_cmd "$NEURON_DLC_VENV_PYTHON"
    if [[ -d "$NEURON_DLC_VENV_DIR" ]]; then
        warn "Venv already exists: $NEURON_DLC_VENV_DIR"
        warn "Re-using it. Remove the directory for a clean rebuild."
    else
        log "Creating venv at $NEURON_DLC_VENV_DIR using $NEURON_DLC_VENV_PYTHON"
        "$NEURON_DLC_VENV_PYTHON" -m venv "$NEURON_DLC_VENV_DIR"
    fi
    # shellcheck source=/dev/null
    source "$NEURON_DLC_VENV_DIR/bin/activate"
    pip install --upgrade pip wheel
    if [[ -z "$NEURON_DLC_WHEEL_GLOBS" ]]; then
        warn "NEURON_DLC_WHEEL_GLOBS is empty; skipping pip installs."
        warn "Set it to a colon-separated list of wheel globs or package dirs"
        warn "under $NEURON_DLC_WORKSPACE_DIR, then re-run with mode=venv."
    else
        local IFS=:
        for glob in $NEURON_DLC_WHEEL_GLOBS; do
            log "pip install $glob"
            # shellcheck disable=SC2086
            ( cd "$NEURON_DLC_WORKSPACE_DIR" && pip install $glob ) || \
                warn "No match or install failure for $glob (skipping)"
        done
    fi
    deactivate
    success "Venv ready: $NEURON_DLC_VENV_DIR"
    log "Activate with: source $NEURON_DLC_VENV_DIR/bin/activate"
}

do_runtime() {
    do_extract
    local deb_dir="$NEURON_DLC_WORKSPACE_DIR/$NEURON_DLC_RUNTIME_DEB_DIR"
    if [[ ! -d "$deb_dir" ]]; then
        die "Runtime deb directory not found: $deb_dir (set NEURON_DLC_RUNTIME_DEB_DIR)"
    fi
    if ! ls "$deb_dir"/*.deb >/dev/null 2>&1; then
        die "No .deb files under $deb_dir"
    fi
    log "Installing on-host runtime packages from $deb_dir"
    need_cmd dpkg
    sudo apt-get update -yq
    sudo apt-get install -yq dkms build-essential
    sudo dpkg -i "$deb_dir"/*.deb || {
        warn "dpkg reported errors; attempting apt-get -f install"
        sudo apt-get -f install -yq
    }
    success "Runtime install complete"
}

do_shell() {
    image_pull
    local image_id
    image_id=$(image_id_of)
    [[ -n "$image_id" ]] || die "Could not find image id after pull"
    log "Starting interactive shell in container (privileged)..."
    exec docker run --rm -it --privileged \
        -v "$NEURON_DLC_WORKSPACE_DIR":/workspace-host \
        "$image_id" /bin/bash
}

case "$MODE" in
    login)   ecr_login ;;
    pull)    image_pull ;;
    shell)   do_shell ;;
    extract) do_extract ;;
    venv)    do_venv ;;
    runtime) do_runtime ;;
    all)     do_extract; do_runtime; do_venv ;;
    *)       die "Unknown mode: $MODE" ;;
esac
