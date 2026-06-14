# Retirement candidates: legacy task runner and JSON task definitions

The new tools/pipeline-runner is verified end-to-end on the production
EC2: every caller now dispatches through the YAML+bash pipelines under
`<consumer>/pipelines/<name>/`, and `make test` enforces that wiring
mechanically. The legacy `setup/single-node/scripts/run-tasks.sh` and
the JSON task definitions it consumed are still present so deploys can
fall back to the old path while operators get used to the switch, but
they are no longer required for any production flow. This document
lists everything that is safe to delete in the same change.

## Hard removal candidates (no consumer left)

### The legacy runner

```
setup/single-node/scripts/run-tasks.sh
```

Reachable only from the dispatch helper's "USE_PIPELINE_RUNNER=false"
branch. Removing it forces every caller through the new runner.

### The 18 JSON task definitions

```
samples/models/qwen-image-edit/tasks/qwen-image-edit-prepare.json
samples/models/qwen-image-edit/tasks/qwen-image-edit-server.json
samples/models/qwen3-vl/tasks/qwen3-vl-prepare.json
samples/models/qwen3-vl/tasks/qwen3-vl-server.json
samples/models/whisper/tasks/whisper-nxd-precompile.json
samples/models/whisper/tasks/whisper-nxd-server.json
samples/models/whisper/tasks/whisper-precompile.json          (also orphan)
samples/models/whisper/tasks/whisper-server.json              (also orphan)
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

Each one was migrated to a YAML+bash pipeline under
`<dir>/pipelines/<name>/` and is no longer referenced from any caller
when `USE_PIPELINE_RUNNER=true`. The dispatch helper still hands the
JSON path through to `run-tasks.sh` when the env var is unset; that
fallback disappears with `run-tasks.sh` itself.

### Documented orphan pipelines

These two YAML pipelines were carried forward from the migration
workflow but no caller invokes them - the NxD-Inference variants
(`whisper-nxd-precompile`, `whisper-nxd-server`) replaced them. The
caller-integration test allowlists both via
`tests/pipelines/test_caller_integration.py::_KNOWN_ORPHAN_PIPELINES`.

```
samples/models/whisper/pipelines/whisper-precompile/
samples/models/whisper/pipelines/whisper-server/
```

Remove the directories AND the matching allowlist entries in the test.

## Soft removal (after the hard removal lands cleanly)

The dispatch helper has a legacy code path that exists only to invoke
`run-tasks.sh`. Once `run-tasks.sh` is gone, that branch is dead code.

```
tools/pipeline-runner/lib-sh/dispatch.sh::_pipeline_dispatch_legacy
```

The same applies to the legacy fall-through inside each caller. After
removing `run-tasks.sh` you can simplify each of these:

- `setup/single-node/scripts/setup-code-server.sh`
- `setup/single-node/scripts/setup-explorer-wrapper.sh`
- `samples/voice-image-edit/scripts/deploy-all.sh`
- `samples/voice-image-edit/app/infra/deploy.sh`
- `samples/neuron-anatomy/scripts/deploy.sh`

so that the `--use-pipeline-runner` flag becomes the only mode and the
fallback prose disappears.

## Order to follow

1. Delete the JSON files and `run-tasks.sh` in one commit.
2. Delete the orphan whisper pipelines + allowlist entries in the same
   commit if you want to keep the file change list short.
3. Run `make test` (the caller-integration test will green-light).
4. In a follow-up, simplify the dispatch helper and each caller (drop
   the legacy branch).

## Verification artefacts

- `make test`: 55 + 250 + 12 = 317 tests pass on the current branch.
- Production EC2 `i-00d82829d3d087a9b` (us-east-2):
    - 9 systemd units active: voice-image-edit-{api,frontend,stream},
      whisper-server-nxd, qwen3-vl, qwen-image-edit, xttsv2-server,
      neuron-anatomy, restore-nvme-symlinks.
    - `/api/edit/health` 200, `/api/edit/generate` 200 (~9 s),
      `/api/edit/tts` 200 (~0.9 s), `/stream/health` 200, frontend 200.
    - `/mnt/local/compiled_models -> /mnt/efs/.../qwen-image-edit-compiled`
      with restore-nvme-symlinks.service replaying the symlink at boot.
- 9 distinct pipeline runs recorded under `.runner-state/runs/` for
  the prod instance, all with `Failed: 0` summaries.
- CW Logs: 8 log groups under `/pipeline-runner/*` populated with
  per-task streams from this deploy.
