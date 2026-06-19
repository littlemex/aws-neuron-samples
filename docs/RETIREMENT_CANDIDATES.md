# JSON task runner retirement — COMPLETED

The legacy `run-tasks.sh` JSON task runner and all 18 JSON task definitions
have been deleted. The two orphan whisper pipelines (`whisper-precompile`,
`whisper-server`) have also been removed. The YAML+bash pipeline runner
(`tools/pipeline-runner`) is now the only dispatch path.

## What was removed

### The legacy runner
```
setup/single-node/scripts/run-tasks.sh
```

### The 18 JSON task definitions
```
samples/models/qwen-image-edit/tasks/qwen-image-edit-prepare.json
samples/models/qwen-image-edit/tasks/qwen-image-edit-server.json
samples/models/qwen3-vl/tasks/qwen3-vl-prepare.json
samples/models/qwen3-vl/tasks/qwen3-vl-server.json
samples/models/whisper/tasks/whisper-nxd-precompile.json
samples/models/whisper/tasks/whisper-nxd-server.json
samples/models/whisper/tasks/whisper-precompile.json
samples/models/whisper/tasks/whisper-server.json
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

### Orphan whisper pipelines
```
samples/models/whisper/pipelines/whisper-precompile/
samples/models/whisper/pipelines/whisper-server/
```

## What was also changed in the same commit

- `USE_PIPELINE_RUNNER` default flipped from `false` to `true` in all
  six caller scripts and in `tools/pipeline-runner/lib-sh/dispatch.sh`.
- `_pipeline_dispatch_legacy` and the `USE_PIPELINE_RUNNER=false` branch
  removed from `dispatch.sh`; the function signature is backward-compatible
  (extra args silently ignored).
- `_KNOWN_ORPHAN_PIPELINES` allowlist cleared in
  `tests/pipelines/test_caller_integration.py`.
- qwen3-vl compile-cache fix ported from JSON into YAML pipeline scripts
  (STEP 0 of the retirement plan).

## Verification

`make test`: 55 + 250 + 12 = 317 tests pass after the deletion.
