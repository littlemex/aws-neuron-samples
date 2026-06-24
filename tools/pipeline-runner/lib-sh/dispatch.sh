#!/usr/bin/env bash
# pipeline-runner dispatch helper.
#
# Sourced by deploy scripts that previously called run-tasks.sh with a JSON
# task definition. The function `pipeline_dispatch` runs the YAML+bash
# pipeline through `run-pipeline`. The JSON/run-tasks.sh path has been
# retired; this is now the only dispatch path.
#
# Required environment when sourcing:
#   REPO_ROOT          absolute path of the repository root
#   AWS_REGION         (or `--region`-equivalent passed via CLI elsewhere)
#
# Optional:
#   AWS_PROFILE        forwarded to the runner if set
#   USE_PIPELINE_RUNNER  accepted but ignored (YAML runner is always used)
#   PIPELINE_RUNNER_LOG_GROUP  CloudWatch log group; defaults to /pipeline-runner/<name>

set -u

# Resolve once and cache so callers that source the helper many times do not
# redo the path calculation.
if [[ -z "${_PIPELINE_RUNNER_BIN:-}" ]]; then
    _PIPELINE_RUNNER_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")/../bin" && pwd)/run-pipeline"
fi

# pipeline_dispatch <instance-id> <region> <legacy-json-path> <new-yml-path> <vars-json> <state-tag>
#
# legacy-json-path and state-tag are accepted for call-site compatibility but
# are no longer used. Only new-yml-path is dispatched.
pipeline_dispatch() {
    local instance_id="$1" region="$2" _legacy_json="$3" new_yml="$4" vars_json="$5" _state_tag="$6"
    _pipeline_dispatch_new "$instance_id" "$region" "$new_yml" "$vars_json"
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
        echo "[NG] jq is required to translate vars JSON for the runner" >&2
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
        # `${arr[@]+"${arr[@]}"}` so an empty array expands to nothing under
        # `set -u`. Bash 3.2 (the /bin/bash shipped on macOS) treats a bare
        # `"${arr[@]}"` on an empty array as an unbound variable and aborts;
        # both var_args (no -v vars) and profile_args (no AWS_PROFILE) can be
        # empty, which broke deploy-all.sh on macOS at the first pipeline step.
        "$_PIPELINE_RUNNER_BIN" run "$new_yml" \
            --instance "$instance_id" \
            --region "$region" \
            ${profile_args[@]+"${profile_args[@]}"} \
            ${var_args[@]+"${var_args[@]}"}
    )
}
