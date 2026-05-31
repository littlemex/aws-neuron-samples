#!/usr/bin/env bash
# capture-and-upload.sh
#
# Run a Python entrypoint that exercises Neuron with profile capture
# turned on, then push the resulting NEFF + NTFF bundle straight into
# the local Neuron Explorer view server using `neuron-explorer upload`.
# All work stays on the trn2 host: nothing round-trips through the
# laptop browser.
#
# Designed to be called both:
#   - interactively (Bootcamp users at the trn2 shell), and
#   - non-interactively (CI / Task Runner job).
#
# The script is idempotent: rerunning with the same --name overwrites
# the prior profile (via `--overwrite`).
#
# ---------------------------------------------------------------------------
# Usage examples
# ---------------------------------------------------------------------------
#
#   # 1) Capture from a Python script and upload as 'matmul-relu-v1'
#   capture-and-upload.sh \
#       --entry /home/coder/explorer-poc/capture_profile.py \
#       --name matmul-relu-v1
#
#   # 2) Reuse an existing profile dir (skip capture, upload only)
#   capture-and-upload.sh \
#       --skip-capture \
#       --profile-dir /home/coder/explorer-poc/profile-out \
#       --name matmul-relu-v1
#
#   # 3) Custom namespace + uploader (useful for team Bootcamps)
#   capture-and-upload.sh \
#       --entry day1/exercise3.py \
#       --name day1-ex3 \
#       --namespace bootcamp-2026 \
#       --uploader alice
#
# ---------------------------------------------------------------------------

set -euo pipefail

# ANSI colours (skip when stdout is not a tty)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'
    BLUE='\033[0;34m'; NC='\033[0m'
else
    GREEN=''; YELLOW=''; RED=''; BLUE=''; NC=''
fi

usage() {
    cat <<EOF
capture-and-upload.sh — capture a Neuron profile and push it to
the local Explorer view server.

Usage: $0 [OPTIONS]

Options:
    --entry PATH                Python script to run with profile capture on.
                                Required unless --skip-capture is set.
    --skip-capture              Do not run --entry; reuse an existing
                                profile directory pointed to by --profile-dir.
    --profile-dir PATH          Profile directory root. When --skip-capture
                                is set this MUST point at a NEFF + NTFF
                                bundle.  When omitted in capture mode it
                                defaults to a fresh dir under \${OUT_ROOT}.
    --name NAME                 Profile name displayed in the Explorer UI.
                                Defaults to <entry-basename>-<unix-time>.
    --namespace NAMESPACE       Profile namespace (default: global).
    --uploader UPLOADER         Uploader displayed in the UI. Defaults to
                                the current Linux user (\$USER).
    --endpoint URL              Explorer view server endpoint
                                (default: http://localhost:3002).
    --no-overwrite              Do NOT pass --overwrite to neuron-explorer.
                                Recommended for write-once history pipelines.
    --extra-flag FLAG           Extra flag forwarded to neuron-explorer
                                upload (may be repeated).  Use this for
                                less-common flags like --source-code.
    --dry-run                   Print the env + commands then exit.
    -h, --help                  Show this help.

Environment:
    OUT_ROOT                    Base dir for capture output. Default:
                                /home/\$(whoami)/explorer-captures

Notes:
    - Requires /opt/aws/neuron/bin/neuron-explorer (Neuron SDK 2.30+).
    - Requires the local Explorer view server to be reachable at
      --endpoint.  Hint: \`systemctl status neuron-explorer\`.
    - We do NOT pass --wait by default because long uploads exceed
      SSM Run Command's 8-minute window.  The Explorer server keeps
      processing in the background; refresh the UI to see the new
      profile move from 'Created' -> 'PROCESSED'.
EOF
}

# ---------------------------------------------------------------------------
# Defaults & arg parsing
# ---------------------------------------------------------------------------
ENTRY=""
SKIP_CAPTURE=false
PROFILE_DIR=""
NAME=""
NAMESPACE="global"
UPLOADER="${USER:-$(id -un)}"
ENDPOINT="http://localhost:3002"
OVERWRITE=true
DRY_RUN=false
EXTRA_FLAGS=()
OUT_ROOT="${OUT_ROOT:-/home/$(id -un)/explorer-captures}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --entry) ENTRY="$2"; shift 2 ;;
        --skip-capture) SKIP_CAPTURE=true; shift ;;
        --profile-dir) PROFILE_DIR="$2"; shift 2 ;;
        --name) NAME="$2"; shift 2 ;;
        --namespace) NAMESPACE="$2"; shift 2 ;;
        --uploader) UPLOADER="$2"; shift 2 ;;
        --endpoint) ENDPOINT="$2"; shift 2 ;;
        --no-overwrite) OVERWRITE=false; shift ;;
        --extra-flag) EXTRA_FLAGS+=("$2"); shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo -e "${RED}[err] unknown option: $1${NC}"; usage; exit 2 ;;
    esac
done

NEURON_EXPLORER="/opt/aws/neuron/bin/neuron-explorer"
[[ -x "$NEURON_EXPLORER" ]] || {
    echo -e "${RED}[err] $NEURON_EXPLORER missing — install Neuron SDK 2.30+${NC}"
    exit 2
}

# ---------------------------------------------------------------------------
# Resolve PROFILE_DIR
# ---------------------------------------------------------------------------
if [[ "$SKIP_CAPTURE" == true ]]; then
    [[ -n "$PROFILE_DIR" ]] || {
        echo -e "${RED}[err] --skip-capture requires --profile-dir${NC}"; exit 2
    }
    [[ -d "$PROFILE_DIR" ]] || {
        echo -e "${RED}[err] profile dir not found: $PROFILE_DIR${NC}"; exit 2
    }
else
    [[ -n "$ENTRY" ]] || {
        echo -e "${RED}[err] --entry is required (or pass --skip-capture)${NC}"; exit 2
    }
    [[ -f "$ENTRY" ]] || {
        echo -e "${RED}[err] entry script not found: $ENTRY${NC}"; exit 2
    }
    if [[ -z "$PROFILE_DIR" ]]; then
        PROFILE_DIR="$OUT_ROOT/$(basename "${ENTRY%.py}")-$(date +%s)"
    fi
    mkdir -p "$PROFILE_DIR"
fi

# ---------------------------------------------------------------------------
# Default NAME if not given
# ---------------------------------------------------------------------------
if [[ -z "$NAME" ]]; then
    if [[ -n "$ENTRY" ]]; then
        NAME="$(basename "${ENTRY%.py}")-$(date +%s)"
    else
        NAME="$(basename "$PROFILE_DIR")"
    fi
fi

# ---------------------------------------------------------------------------
# Plan
# ---------------------------------------------------------------------------
echo -e "${BLUE}=== plan ===${NC}"
echo "  entry        : ${ENTRY:-<skip>}"
echo "  profile dir  : $PROFILE_DIR"
echo "  name         : $NAME"
echo "  namespace    : $NAMESPACE"
echo "  uploader     : $UPLOADER"
echo "  endpoint     : $ENDPOINT"
echo "  overwrite    : $OVERWRITE"

if [[ "$DRY_RUN" == true ]]; then
    echo -e "${YELLOW}[dry-run] exit before doing any work${NC}"
    exit 0
fi

# ---------------------------------------------------------------------------
# Capture
# ---------------------------------------------------------------------------
if [[ "$SKIP_CAPTURE" != true ]]; then
    echo -e "${BLUE}=== capture ===${NC}"
    # NEURON_RT_INSPECT_* env vars must be set BEFORE neuron-rt symbols
    # resolve, so we export them here and let the entry script inherit.
    export NEURON_RT_INSPECT_ENABLE=1
    export NEURON_RT_INSPECT_DEVICE_PROFILE=1
    export NEURON_RT_ENABLE_DGE_NOTIFICATIONS=1
    export NEURON_RT_INSPECT_OUTPUT_DIR="$PROFILE_DIR"
    : "${NEURON_CC_FLAGS:=--target trn2 --lnc 1}"
    export NEURON_CC_FLAGS

    echo "    NEURON_RT_INSPECT_OUTPUT_DIR=$PROFILE_DIR"
    echo "    NEURON_CC_FLAGS=$NEURON_CC_FLAGS"
    echo "    -> python $ENTRY"
    python "$ENTRY"
    echo -e "${GREEN}[OK] capture done${NC}"
fi

# ---------------------------------------------------------------------------
# Locate the actual run dir under PROFILE_DIR
# ---------------------------------------------------------------------------
# `neuron-rt-inspect` writes into <PROFILE_DIR>/<host>_pid_<pid>/<run-id>/.
# `neuron-explorer upload --profile-directory` accepts the run-id dir,
# so we hand the deepest non-empty leaf that contains an .ntff file.
RUN_DIR=""
while IFS= read -r dir; do
    if find "$dir" -maxdepth 1 -name "*.ntff" -print -quit | grep -q .; then
        RUN_DIR="$dir"
        break
    fi
done < <(find "$PROFILE_DIR" -mindepth 1 -maxdepth 4 -type d 2>/dev/null | sort -r)

if [[ -z "$RUN_DIR" ]]; then
    echo -e "${RED}[err] no .ntff under $PROFILE_DIR — capture failed?${NC}"
    exit 1
fi
echo -e "${BLUE}=== upload ===${NC}"
echo "  run dir   : $RUN_DIR"
echo "  contents  :"
ls -la "$RUN_DIR" | sed 's/^/      /'

# ---------------------------------------------------------------------------
# Upload
# ---------------------------------------------------------------------------
UPLOAD_ARGS=(
    upload
    --endpoint "$ENDPOINT"
    --uploader "$UPLOADER"
    --namespace "$NAMESPACE"
    --name "$NAME"
    --profile-directory "$RUN_DIR"
)
[[ "$OVERWRITE" == true ]] && UPLOAD_ARGS+=(--overwrite)
for f in "${EXTRA_FLAGS[@]}"; do UPLOAD_ARGS+=("$f"); done

# We deliberately DO NOT pass --wait.  Long captures push the upload
# past SSM Run Command's 8-minute window, but the server processes
# asynchronously; the user can refresh the UI to track status.
echo "  -> $NEURON_EXPLORER ${UPLOAD_ARGS[*]}"
"$NEURON_EXPLORER" "${UPLOAD_ARGS[@]}"
rc=$?

if [[ $rc -eq 0 ]]; then
    echo -e "${GREEN}[OK] upload submitted (rc=0)${NC}"
    echo
    echo "Open Explorer to inspect the profile:"
    echo "  https://<your-cloudfront>/explorer/profiles"
    echo "  -> Search Profiles tab"
    echo "  -> profile name: $NAME (uploader=$UPLOADER, namespace=$NAMESPACE)"
else
    echo -e "${RED}[err] neuron-explorer upload exited rc=$rc${NC}"
    exit $rc
fi
