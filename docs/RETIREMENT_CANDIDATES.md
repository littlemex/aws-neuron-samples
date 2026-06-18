# Retirement candidates: legacy task runner and JSON task definitions

The new tools/pipeline-runner is verified end-to-end on the production
EC2: every caller now dispatches through the YAML+bash pipelines under
`<consumer>/pipelines/<name>/`, and `make test` enforces that wiring
mechanically. This document is the single source of truth for what to
delete and how. Run the commands below verbatim and `make test` will
stay green.

## TL;DR - one-shot commands

Run from the repo root. These delete every retirement candidate listed
in this document in one commit:

```bash
# 1. The legacy runner.
git rm setup/single-node/scripts/run-tasks.sh

# 2. All 18 JSON task definitions and their parent tasks/ dirs.
git rm -r samples/models/qwen-image-edit/tasks
git rm -r samples/models/qwen3-vl/tasks
git rm -r samples/models/whisper/tasks
git rm -r samples/models/xttsv2/tasks
git rm -r samples/neuron-anatomy/scripts/tasks
git rm -r samples/voice-image-edit/app/infra/tasks
git rm -r samples/voice-image-edit/scripts/tasks
git rm -r setup/single-node/tasks

# 3. The two orphan whisper pipelines superseded by the NxD variants.
git rm -r samples/models/whisper/pipelines/whisper-precompile
git rm -r samples/models/whisper/pipelines/whisper-server
```

After staging the deletions, edit the test allowlist:

```python
# tests/pipelines/test_caller_integration.py
# Replace _KNOWN_ORPHAN_PIPELINES with:
_KNOWN_ORPHAN_PIPELINES: dict[str, str] = {}
```

Then verify and commit:

```bash
make test            # 317 passed, 0 failed expected
git commit -m "chore: retire legacy task runner and migrated JSON definitions"
```

## Detailed file list

### A. Legacy runner (1 file)

```
setup/single-node/scripts/run-tasks.sh
```

The Python-in-bash task executor that the pipelines used before the YAML
runner shipped. Reachable today only from the dispatch helper's
`USE_PIPELINE_RUNNER=false` branch.

### B. Migrated JSON task definitions (18 files)

Every entry has a 1:1 YAML replacement under
`<dir>/pipelines/<name>/<name>.yml`. The dispatch helper still hands the
JSON path through to `run-tasks.sh` when the env var is unset; that
fallback disappears with `run-tasks.sh` itself.

```
samples/models/qwen-image-edit/tasks/qwen-image-edit-prepare.json
samples/models/qwen-image-edit/tasks/qwen-image-edit-server.json
samples/models/qwen3-vl/tasks/qwen3-vl-prepare.json
samples/models/qwen3-vl/tasks/qwen3-vl-server.json
samples/models/whisper/tasks/whisper-nxd-precompile.json
samples/models/whisper/tasks/whisper-nxd-server.json
samples/models/whisper/tasks/whisper-precompile.json          (also orphan, see C)
samples/models/whisper/tasks/whisper-server.json              (also orphan, see C)
samples/models/xttsv2/tasks/xttsv2-precompile.json
samples/models/xttsv2/tasks/xttsv2-server.json
samples/neuron-anatomy/scripts/tasks/neuron-anatomy-server.json
samples/voice-image-edit/app/infra/tasks/voice-image-edit-api.json
samples/voice-image-edit/app/infra/tasks/voice-image-edit-frontend.json
samples/voice-image-edit/app/infra/tasks/voice-image-edit-stream.json
samples/voice-image-edit/scripts/tasks/migrate-to-efs.json
samples/voice-image-edit/scripts/tasks/setup-efs-paths.json
setup/single-node/tasks/code-server-setup.json
setup/single-node/tasks/explorer-setup.json
```

The corresponding `tasks/` directories all become empty after deletion;
remove them too (the `git rm -r` commands above already handle that).

### C. Orphan pipelines superseded by NxD variants (2 directories)

Carried forward from the migration workflow but no caller invokes them.
The NxD-Inference variants (`whisper-nxd-precompile`,
`whisper-nxd-server`) replaced them. The caller-integration test
allowlists both via
`tests/pipelines/test_caller_integration.py::_KNOWN_ORPHAN_PIPELINES`.

```
samples/models/whisper/pipelines/whisper-precompile/
samples/models/whisper/pipelines/whisper-server/
```

After removing both directories, also remove the matching allowlist
entries (instructions in section "Test allowlist" below).

### D. Test allowlist (1 dict)

```
tests/pipelines/test_caller_integration.py
```

Replace the body of `_KNOWN_ORPHAN_PIPELINES` with `{}` once the orphan
whisper pipelines are gone:

```python
_KNOWN_ORPHAN_PIPELINES: dict[str, str] = {}
```

(The variable still has to exist; only its content is empty. The test
that pins the allowlist to reality will fail otherwise.)

## After this commit lands - follow-up cleanup (optional)

Once `run-tasks.sh` is gone, the legacy code path inside the dispatch
helper is dead code. The same applies to each caller's `if
USE_PIPELINE_RUNNER == true` branch and its surrounding fallback prose.
None of these are required for the system to keep working; they just
add lines to read.

Files where the legacy branch can be simplified away:

- `tools/pipeline-runner/lib-sh/dispatch.sh`
  (delete `_pipeline_dispatch_legacy` and the `if/else` in
   `pipeline_dispatch`; the function becomes a one-liner that calls
   `_pipeline_dispatch_new` unconditionally)
- `setup/single-node/scripts/setup-code-server.sh`
  (delete the `if [[ "$USE_PIPELINE_RUNNER" == "true" ]]` info block
   and the legacy resume branch; always invoke `pipeline_dispatch`)
- `setup/single-node/scripts/setup-explorer-wrapper.sh`
  (same pattern)
- `samples/voice-image-edit/scripts/deploy-all.sh`
  (delete the legacy fall-through inside `run_task_json`; drop the
   `--use-pipeline-runner` plumbing as the only mode)
- `samples/voice-image-edit/app/infra/deploy.sh`
  (delete the YAML-missing fallback inside `run_task`)
- `samples/neuron-anatomy/scripts/deploy.sh`
  (same)

Suggested order: do the deletions first (commit A above), confirm
`make test` is green, then file the simplification as a separate
follow-up PR.

## Verification checklist

After each step:

1. `make test` -> 55 + 250 + 12 = 317 passed, 0 failed.
2. `grep -rn "run-tasks.sh" -- :^docs/RETIREMENT_CANDIDATES.md` -> no
   matches outside this document.
3. `find samples setup -path '*/tasks' -type d` -> empty.
4. `./tools/pipeline-runner/bin/run-pipeline list` -> existing run
   history still readable.

If step 1 fails, the most likely culprit is the test allowlist (section
D); update `_KNOWN_ORPHAN_PIPELINES` to `{}`.

## Why we are confident the new runner replaces the legacy one

- Production EC2 `i-00d82829d3d087a9b` (us-east-2) was redeployed
  end-to-end via `deploy-all.sh --use-pipeline-runner`. All 9 systemd
  units are active: voice-image-edit-{api,frontend,stream},
  whisper-server-nxd, qwen3-vl, qwen-image-edit, xttsv2-server,
  neuron-anatomy, restore-nvme-symlinks.
- Endpoint smoke after the deploy: `/api/edit/health` 200,
  `/api/edit/generate` 200 (~9 s, Stability us-west-2),
  `/api/edit/tts` 200 (~0.9 s, Polly us-east-1), `/stream/health` 200,
  frontend 200.
- `/mnt/local/compiled_models -> /mnt/efs/.../qwen-image-edit-compiled`
  is reinstated on every boot by restore-nvme-symlinks.service.
- `.runner-state/runs/` records 9 separate pipeline runs from that
  deploy, each with `Failed: 0`.
- CW Logs has 8 log groups under `/pipeline-runner/*` populated with
  per-task streams from this deploy, which only the new runner writes
  to.
