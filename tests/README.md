# Tests

A four-layer harness so that `make test` is the single source of truth for
"is this branch shippable".

```
tests/
  rules/                     # Layer 3: language / style policy enforcement
    test_english_only.py     #   pipeline-runner sources must be English
    test_no_emoji.py         #   no emoji in committed sources
    test_no_co_authored.py   #   no "Co-authored-by:" in commit messages
    test_env_required.py     #   engine layer must use env_required(), not os.environ.get
  pipelines/                 # Layer 2: every YAML+bash pipeline is wired correctly
    test_bash_syntax.sh      #   bash -n on every script under pipelines/**/scripts/
    test_dry_run.py          #   run-pipeline --dry-run for every YAML
    test_persistence.py      #   no critical artifact written to NVMe ephemeral
    test_required_vars.py    #   YAML required_vars covers every ${VAR} the script reads
tools/pipeline-runner/tests/ # Layer 1: runner internals
  test_durations.py
  test_pipeline.py
  test_fingerprint.py
  test_state.py
  test_executor.py
```

Layer 4 is the top-level `Makefile` at the repo root. `make test` runs
all four; sub-targets are `make test-unit`, `make test-pipelines`,
`make test-rules`, `make test-fast` (skips dry-run).

## Why these rules exist

- **English-only policy on pipeline-runner sources** — the runner is the
  shared tool that every consumer pipeline depends on. Mixed-language
  comments invariably produce text-to-speech failures (read-aloud demos)
  and read-poorly to non-Japanese-speaking contributors.
- **No-emoji policy** — emoji break grep / search-by-text and clutter
  diffs. Use `[OK]`, `[NG]`, `[WARN]` text tags instead.
- **No "Co-authored-by:" commit trailer** — this repo's policy: every
  commit is attributed to the human author only.
- **`env_required()` over `os.environ.get(K, default)`** — silent
  fallbacks have caused two production incidents already (the wrong
  Bedrock region; a stale Trainium model id). The engine layer must
  fail fast.

The actual test files contain authoritative comments explaining every
decision; the rules above are summaries.
