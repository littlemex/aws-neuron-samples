# pipeline-runner

A small declarative runner for SSM-driven, idempotent EC2 deploy pipelines.

The runner replaces `setup/single-node/scripts/run-tasks.sh` and the JSON task
definitions under `samples/**/tasks/`. It is designed around three properties
the older runner could not give us: **resumability**, **observability**, and
**long-running tasks** that survive 24 KB SSM output truncation.

## Why a new runner

The previous runner stored each task as a JSON array of one-line shell
commands. That format has four structural problems:

1. **No comments, no shellcheck.** A 30-line systemd unit body has to be
   sliced into 30 JSON array elements with `'\\''` triple escapes.
2. **No per-task timeout.** A single `TASK_MAX_WAIT_SECONDS` env var applies
   to every task, so a 90-minute Neuron compile and a 30-second precheck
   share the same watchdog.
3. **24 KB output truncation.** SSM `get-command-invocation` truncates
   `StandardOutputContent` at 24 KB, and the old runner did not configure
   `CloudWatchOutputConfig`, so long-running task logs were silently lost.
4. **Sequential-only.** `for task in tasks: run(task)` with no DAG, so
   independent stacks (api / frontend / stream) were forced to run in series.

This runner keeps all the things that worked - idempotency, content-addressed
fingerprints, presigned-S3-URL-aware caching - and fixes the four problems
above without expanding the scope.

## Layout

```
tools/pipeline-runner/
  bin/run-pipeline           # the CLI entry point (Python 3.9+, single file)
  lib/                       # split modules used by bin/run-pipeline
  examples/                  # tiny example pipeline + scripts
  README.md                  # this file
```

A pipeline lives next to its consumer, not under `tools/`:

```
samples/voice-image-edit/app/infra/pipelines/
  voice-image-edit-api.yml
  scripts/
    00-precheck.sh
    20-deploy-tarball.sh
    30-create-venv.sh
    40-install-systemd-unit.sh
    50-enable-start.sh
    60-health-check.sh
```

The shell files are plain bash. They can be edited, `shellcheck`ed, and run
locally with mocked env vars without going through the runner.

## Pipeline schema

```yaml
name: voice-image-edit-api
description: |
  Deploys the FastAPI backend that backs /api/edit/* on the shared EC2.

# Default values for variables. Tasks see these through the SSM environment;
# the runner never expands `{{NAME}}` placeholders inside scripts.
vars:
  API_PORT: "8801"
  API_USER: ubuntu
  API_DIR: /opt/voice-image-edit/api

# Variables that MUST be supplied at invocation time. The runner refuses to
# start if any of them is missing or empty.
required_vars:
  - API_TARBALL_URL
  - AWS_REGION
  - BEDROCK_REGION
  - EDIT_BEDROCK_REGION
  - GENERATE_BEDROCK_REGION
  - POLLY_REGION

# Defaults applied to every task unless overridden.
defaults:
  timeout: 5m
  retries: 0
  cloudwatch_logs: true

# Maximum number of tasks executed concurrently. Tasks with a `needs:`
# dependency only run once their dependencies have completed.
max_concurrency: 4

tasks:
  - id: 00-precheck
    timeout: 30s
    script: scripts/00-precheck.sh

  - id: 20-deploy-tarball
    needs: [00-precheck]
    timeout: 3m
    script: scripts/20-deploy-tarball.sh
    # Inputs whose change should invalidate this task's fingerprint, on top of
    # the script body and the task env. Values starting with `s3://` or `https://`
    # are resolved through the S3 head-object ETag so re-presigning the same
    # object does not invalidate the cache.
    fingerprint_inputs:
      - "{{API_TARBALL_URL}}"

  - id: 30-create-venv
    needs: [20-deploy-tarball]
    timeout: 5m
    script: scripts/30-create-venv.sh

  - id: 40-install-systemd-unit
    needs: [30-create-venv]
    timeout: 1m
    script: scripts/40-install-systemd-unit.sh

  - id: 50-enable-start
    needs: [40-install-systemd-unit]
    timeout: 90s
    script: scripts/50-enable-start.sh

  - id: 60-health-check
    needs: [50-enable-start]
    timeout: 90s
    retries: 5
    retry_delay: 5s
    script: scripts/60-health-check.sh
```

### Field reference

| Field | Type | Notes |
|---|---|---|
| `name` | string | Used as the run namespace. |
| `description` | string | Free text, ignored by the runner. |
| `vars` | mapping | Default variable values. Strings only. |
| `required_vars` | list[string] | Empty values are rejected at startup. |
| `defaults.timeout` | duration (`30s`/`5m`/`2h`) | Applied per task unless overridden. |
| `defaults.retries` | int | 0 means run-once. |
| `defaults.retry_delay` | duration | Wait between retries. |
| `defaults.cloudwatch_logs` | bool | Configures `CloudWatchOutputConfig`. |
| `max_concurrency` | int | Slot cap for parallel execution. |
| `tasks[].id` | string | Must be unique. |
| `tasks[].script` | path | Relative to the pipeline file. |
| `tasks[].needs` | list[string] | Dependency ids. |
| `tasks[].timeout` | duration | Per-task watchdog. |
| `tasks[].retries` | int | Override of `defaults.retries`. |
| `tasks[].retry_delay` | duration | Override of `defaults.retry_delay`. |
| `tasks[].fingerprint_inputs` | list[string] | Extra fingerprint inputs (`{{NAME}}` substituted, S3 URLs replaced by their ETag). |

## Script contract

A task script is a plain `#!/usr/bin/env bash` file. Variables become
environment variables (`API_PORT`, `BEDROCK_REGION`, ...). The runner never
template-expands the body, so quoting/heredocs work the way bash users
expect.

```bash
#!/usr/bin/env bash
set -euo pipefail

# All required_vars are guaranteed non-empty at this point (the runner
# refused to start otherwise), so we only validate locally-introduced state.
test -d "$API_DIR" || { echo "[NG] API_DIR=$API_DIR missing"; exit 1; }
test -x "$API_DIR/venv/bin/python" || { echo "[NG] venv/bin/python missing"; exit 1; }
echo "[OK] precheck"
```

## CLI

```
run-pipeline run    <pipeline.yml> --instance i-xxx --region us-east-2 [-v K=V ...]
run-pipeline run    <pipeline.yml> --instance i-xxx --detach            # background
run-pipeline status <run-id>                                            # summary
run-pipeline attach <run-id>                                            # tail CW Logs
run-pipeline list                                                        # known runs
run-pipeline resume <run-id>                                            # continue
run-pipeline rerun  <run-id> --from <task-id>                            # force re-execute
```

A few details worth pointing out:

- `--vars-file FILE` accepts a flat `KEY=VALUE` env-style file. CLI `-v K=V`
  pairs override entries from the file.
- `--detach` returns immediately with a `run-id`. The runner forks itself as
  a background process; subsequent CW Logs tailing happens through `attach`.
- `--from-task <id>` is implied by `rerun`. It reruns the named task plus
  every transitively dependent task.

## State

The runner stores state under the repository:

```
.runner-state/
  <pipeline-name>/
    <instance-id>.json     # latest fingerprints + status, used for resume
  runs/
    <run-id>.jsonl         # structured per-task event log (start/end/retry/log_stream)
```

`.runner-state/` is `.gitignore`d.

The state file is keyed on `(pipeline-name, instance-id)` because the same
pipeline often runs against multiple instances. Run logs are append-only
JSONL so they can be `tail -f`ed and scraped with `jq`.

## Fingerprints

A task is skipped when its fingerprint matches the recorded one. The
fingerprint is `sha256(...)` over, in order:

1. The script file body (post-shebang).
2. All env vars passed to the task, sorted by key.
3. Each `fingerprint_inputs` entry, after `{{NAME}}` expansion. Values that
   look like S3 URLs (presigned or `s3://`) are replaced by the object's
   ETag through one `head-object` call (cached for the run).

When the fingerprint changes, the runner prints a per-input diff so the
operator knows whether the script, an env var, or an S3 object actually moved.

## CloudWatch Logs

Every task that has `cloudwatch_logs: true` (the default) is launched with
`--cloud-watch-output-config CloudWatchLogGroupName=...,CloudWatchOutputEnabled=true`.

The log group is `/pipeline-runner/<pipeline-name>` and the stream key is
`<run-id>/<task-id>`. The runner tails the stream live; on `--detach` the
stream is the only place full output lives.

This bypasses the SSM `StandardOutputContent` 24 KB truncation entirely. The
runner still records the SSM `commandId` in state for traceability.

## Long-running tasks

The runner watchdog and the SSM `TimeoutSeconds` are kept in sync from
`tasks[].timeout`. The SSM API allows up to 172800 seconds (48 hours), which
is enough for any compile we run today.

If the local watchdog fires first, the runner cancels the SSM invocation
explicitly so the EC2 side does not keep running.

## Migration plan

The new runner ships next to the old one, not on top of it. Existing
pipelines keep using `run-tasks.sh` until they are migrated explicitly:

1. Add the new runner under `tools/pipeline-runner/`.
2. Migrate `voice-image-edit-api` first, with `deploy.sh --use-pipeline-runner`
   selecting the new path. The old `tasks/voice-image-edit-api.json` stays
   intact.
3. Migrate the remaining 17 task definitions one by one.
4. Remove `setup/single-node/scripts/run-tasks.sh` once all callers are off
   it.

## Non-goals

The runner intentionally does NOT cover:

- Cross-account / cross-region fan-out. One pipeline targets one region at a
  time. Use multiple invocations.
- Secret management. Pass secrets through env vars; the runner never logs
  variable values.
- Templated control flow (`if`, `for`, `with`). That is what bash is for.
