#!/usr/bin/env bash
# bootstrap.sh - bring up Pi0.5 LoRA fine-tune on a trn2.3xlarge.
#
# What this script does on the EC2 instance:
#   1. Fresh-clone openpi at a pinned commit (BASE_COMMIT) and reset/clean
#      any stale checkout so reruns are idempotent.
#   2. Apply patches/*.patch in lexicographic order via `git apply`.
#   3. Create a uv-managed venv and install openpi + jax-neuronx.
#   4. Sync the pi05_base ckpt into /mnt/local/cache-coder.
#   5. Run scripts/train.py for one step with WANDB disabled and the
#      Trainium-compatible NEURON_CC_FLAGS, logging to ${WORK_DIR}/runs/.
#   6. Print the "Step 0:" line so callers can confirm reproduction.
#
# Run as the coder user (the DLAMI deploy.sh provisioned). reproduce.sh
# launches it through SSM with `sudo -u coder`.

set -euo pipefail

# ---- defaults ----------------------------------------------------------

WORK_DIR="${WORK_DIR:-/work/openpi-pi05-lora-reproduce}"
OPENPI_DIR="${WORK_DIR}/openpi"
VENV_DIR="${WORK_DIR}/.venv"
PATCHES_DIR="${WORK_DIR}/patches"
RUNS_DIR="${WORK_DIR}/runs"
CKPT_CACHE_DIR="${CKPT_CACHE_DIR:-/mnt/local/cache-coder/openpi/openpi-assets/checkpoints}"

BASE_COMMIT="${BASE_COMMIT:-c23745b5ad24e98f66967ea795a07b2588ed6c79}"
OPENPI_REPO="${OPENPI_REPO:-https://github.com/Physical-Intelligence/openpi.git}"

PI05_CONFIG="${PI05_CONFIG:-pi05_aloha_pen_uncap_lora}"
EXP_NAME="${EXP_NAME:-pi05_lora_trn2_$(date +%Y%m%d-%H%M%S)}"
NUM_TRAIN_STEPS="${NUM_TRAIN_STEPS:-1}"
BATCH_SIZE="${BATCH_SIZE:-4}"

VENV_PATH="${VENV_DIR}/bin"

log() {
    echo "[bootstrap $(date -u +%H:%M:%S)] $*"
}

# ---- phase A: openpi clone + patches ----------------------------------

mkdir -p "${WORK_DIR}" "${RUNS_DIR}"

if [[ ! -d "${OPENPI_DIR}/.git" ]]; then
    log "fresh-cloning openpi at ${BASE_COMMIT}"
    git clone --depth=200 "${OPENPI_REPO}" "${OPENPI_DIR}"
    git -C "${OPENPI_DIR}" checkout "${BASE_COMMIT}"
else
    log "openpi clone exists; resetting to ${BASE_COMMIT} for idempotent rerun"
    git -C "${OPENPI_DIR}" reset --hard "${BASE_COMMIT}"
    git -C "${OPENPI_DIR}" clean -fdx -e venv -e .venv
fi

if [[ ! -d "${PATCHES_DIR}" ]]; then
    log "patches/ directory not found at ${PATCHES_DIR}" >&2
    exit 2
fi

log "applying patches"
shopt -s nullglob
for P in "${PATCHES_DIR}"/*.patch; do
    log "  apply $(basename "${P}")"
    git -C "${OPENPI_DIR}" apply --check "${P}"
    git -C "${OPENPI_DIR}" apply "${P}"
done
shopt -u nullglob

# Sanity: 6 modified files expected. Anything less means a patch silently
# matched zero hunks and the diff is incomplete.
MODIFIED_COUNT="$(git -C "${OPENPI_DIR}" status --porcelain | wc -l)"
if [[ "${MODIFIED_COUNT}" -lt 5 ]]; then
    log "WARNING: modified-file count (${MODIFIED_COUNT}) is below expected"
fi

# ---- phase B: venv (uv) + dependencies --------------------------------

if [[ ! -x "${VENV_PATH}/python" ]]; then
    log "creating venv via uv (Python 3.12)"
    if ! command -v uv >/dev/null 2>&1; then
        log "uv not found, installing via curl"
        curl -LsSf https://astral.sh/uv/install.sh | sh
        export PATH="${HOME}/.local/bin:${PATH}"
    fi
    uv venv --python 3.12 "${VENV_DIR}"
fi

# jax-neuronx and the neuron pjrt extras live behind the AWS Neuron pip index.
if [[ ! -f "${VENV_DIR}/.deps-installed" ]]; then
    log "installing openpi + jax-neuronx into the venv"
    (
        cd "${OPENPI_DIR}"
        export VIRTUAL_ENV="${VENV_DIR}"
        uv pip install -e .
        uv pip install jax-neuronx neuronx-cc==2.25.* libneuronxla==3.0.* \
            --extra-index-url https://pip.repos.neuron.amazonaws.com
    )
    touch "${VENV_DIR}/.deps-installed"
fi

# ---- phase C: pi05_base checkpoint cache ------------------------------

mkdir -p "${CKPT_CACHE_DIR}"
if [[ ! -d "${CKPT_CACHE_DIR}/pi05_base/params" ]]; then
    log "syncing pi05_base/params (12.5 GiB) from gs:// into the local cache"
    "${VENV_PATH}/python" - <<'PYEOF'
import os
import openpi.shared.download as download
download.maybe_download("gs://openpi-assets/checkpoints/pi05_base/params")
download.maybe_download("gs://openpi-assets/checkpoints/pi05_base/assets")
PYEOF
fi

# ---- phase D: run a single LoRA training step -------------------------

LOGF="${RUNS_DIR}/${EXP_NAME}.log"
WD="${RUNS_DIR}/${EXP_NAME}.workdir"
mkdir -p "${WD}"

log "starting LoRA train (config=${PI05_CONFIG}, steps=${NUM_TRAIN_STEPS}, batch=${BATCH_SIZE})"
log "  log:    ${LOGF}"
log "  neuron workdir: ${WD}"

# NEURON_CC_FLAGS only takes --logfile and --verbose=*; --tmpdir / --no-cache
# are NOT accepted (NCC_EARG002). NEURONX_DUMP_TO replaces --tmpdir.
# WANDB is disabled here to avoid prompting for an API key.

cd "${OPENPI_DIR}"
set +e
PATH="${VENV_PATH}:${PATH}" \
WANDB_MODE=disabled \
NEURON_FRAMEWORK_DEBUG=1 \
NEURONX_DUMP_TO="${WD}" \
NEURON_CC_FLAGS="--logfile=${WD}/log-neuron-cc.txt --verbose=info" \
"${VENV_PATH}/python" scripts/train.py "${PI05_CONFIG}" \
    --exp-name="${EXP_NAME}" \
    --num-train-steps="${NUM_TRAIN_STEPS}" \
    --batch-size="${BATCH_SIZE}" \
    --no-wandb-enabled \
    > "${LOGF}" 2>&1
RC=$?
set -e

log "train.py exit code = ${RC}"
log "Step 0 line (expect 'loss=..., grad_norm=...'):"
grep -E "Step [0-9]+:" "${LOGF}" | tail -5 || true

if [[ "${RC}" -ne 0 ]]; then
    log "train.py failed; tailing log + neuron-cc diagnostic:"
    tail -40 "${LOGF}" || true
    if [[ -f "${WD}/log-neuron-cc.txt" ]]; then
        echo "--- log-neuron-cc.txt tail ---"
        tail -30 "${WD}/log-neuron-cc.txt" || true
    fi
    exit "${RC}"
fi

log "reproduction finished: ${LOGF}"
