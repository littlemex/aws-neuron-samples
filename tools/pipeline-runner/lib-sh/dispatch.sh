#!/usr/bin/env bash
# pipeline-runner dispatch helper.
#
# Sourced by deploy scripts that historically called run-tasks.sh with a
# JSON task definition. The function `pipeline_dispatch` delegates to one
# of two backends depending on the USE_PIPELINE_RUNNER environment variable:
#
#   USE_PIPELINE_RUNNER=true   -> run-pipeline run <pipeline.yml> ...
#   USE_PIPELINE_RUNNER=false  -> run-tasks.sh -f <task.json> -v <vars-json>
#
# Callers pass BOTH the legacy JSON path and the new YAML path so the
# switch is a single environment variable away. They also pass a single
# vars-JSON string; for the new runner it is split into -v KEY=VALUE pairs
# automatically (jq required).
#
# This helper deliberately does NOT take a pipeline name as an argument:
# the pipeline name is read from the YAML's `name:` field by run-pipeline,
# and the legacy state file uses the basename of the JSON task file.
#
# Required environment when sourcing:
#   REPO_ROOT          absolute path of the repository root
#   AWS_REGION         (or `--region`-equivalent passed via CLI elsewhere)
#
# Optional:
#   AWS_PROFILE        forwarded to both backends if set
#   USE_PIPELINE_RUNNER  defaults to "false"
#   PIPELINE_RUNNER_LOG_GROUP  CloudWatch log group; defaults to /pipeline-runner/<name>

set -u

# Resolve once and cache, so callers that source the helper many times do
# not re-do the path math.
if [[ -z "${_PIPELINE_RUNNER_BIN:-}" ]]; then
    _PIPELINE_RUNNER_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/run-pipeline"
fi

if [[ -z "${_LEGACY_RUN_TASKS_BIN:-}" ]]; then
    # The legacy script lives under setup/single-node/scripts/run-tasks.sh.
    # We resolve from the helper's location so callers do not need to know.
    _LEGACY_RUN_TASKS_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)/setup/single-node/scripts/run-tasks.sh"
fi

# pipeline_dispatch <instance-id> <region> <legacy-json-path> <new-yml-path> <vars-json> <state-tag>
#
# state-tag is used only for the legacy path (the new path keys state on
# the YAML's `name:` field automatically). Pass any short label.
pipeline_dispatch() {
    local instance_id="$1" region="$2" legacy_json="$3" new_yml="$4" vars_json="$5" state_tag="$6"

    local use_new="${USE_PIPELINE_RUNNER:-false}"

    if [[ "$use_new" == "true" ]]; then
        _pipeline_dispatch_new "$instance_id" "$region" "$new_yml" "$vars_json"
    else
        _pipeline_dispatch_legacy "$instance_id" "$region" "$legacy_json" "$vars_json" "$state_tag"
    fi
}

_pipeline_dispatch_new() {
    local instance_id="$1" region="$2" new_yml="$3" vars_json="$4"

    if [[ ! -x "$_PIPELINE_RUNNER_BIN" ]]; then
        echo "[NG] pipeline-runner not found or not executable at $_PIPELINE_RUNNER_BIN" >&2
        return 1
    fi
    if [[ ! -f "$new_yml" ]]; then
        echo "[NG] pipeline YAML not found at $new_yml" >&2
        return 1
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "[NG] jq is required to translate the legacy vars-JSON for the new runner" >&2
        return 1
    fi
    if ! command -v python3 >/dev/null 2>&1; then
        echo "[NG] python3 is required for the pipeline runner" >&2
        return 1
    fi
    if ! python3 -c 'import yaml' >/dev/null 2>&1; then
        echo "[NG] PyYAML missing. Install with: pip3 install --user pyyaml" >&2
        return 1
    fi

    local var_args=()
    local line
    while IFS= read -r line; do
        var_args+=("-v" "$line")
    done < <(jq -r 'to_entries[] | "\(.key)=\(.value)"' <<<"$vars_json")

    local profile_args=()
    if [[ -n "${AWS_PROFILE:-}" ]]; then
        profile_args+=(--profile "$AWS_PROFILE")
    fi

    local cwd_anchor="${REPO_ROOT:-$PWD}"
    (
        cd "$cwd_anchor"
        "$_PIPELINE_RUNNER_BIN" run "$new_yml" \
            --instance "$instance_id" \
            --region "$region" \
            "${profile_args[@]}" \
            "${var_args[@]}"
    )
}

_pipeline_dispatch_legacy() {
    local instance_id="$1" region="$2" legacy_json="$3" vars_json="$4" state_tag="$5"

    if [[ ! -x "$_LEGACY_RUN_TASKS_BIN" ]]; then
        echo "[NG] legacy run-tasks.sh not found at $_LEGACY_RUN_TASKS_BIN" >&2
        return 1
    fi
    if [[ ! -f "$legacy_json" ]]; then
        echo "[NG] legacy task JSON not found at $legacy_json" >&2
        return 1
    fi

    # Match the previous deploy.sh state-file convention so re-running the
    # same caller does not invalidate the legacy cache when the new path
    # is gated off.
    local state_file="/tmp/task-state-${instance_id}-${state_tag}.json"

    "$_LEGACY_RUN_TASKS_BIN" \
        -i "$instance_id" \
        -r "$region" \
        -f "$legacy_json" \
        -v "$vars_json" \
        --state-file "$state_file"
}
