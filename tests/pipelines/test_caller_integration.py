"""Caller-side integration checks.

Five top-level scripts are responsible for kicking off pipelines:

  - setup/single-node/scripts/setup-code-server.sh
  - setup/single-node/scripts/setup-explorer-wrapper.sh
  - samples/voice-image-edit/scripts/deploy-all.sh
  - samples/voice-image-edit/app/infra/deploy.sh
  - samples/neuron-anatomy/scripts/deploy.sh

Each of them must:
  - source tools/pipeline-runner/lib-sh/dispatch.sh (so the new runner
    is reachable through pipeline_dispatch).
  - accept a `--use-pipeline-runner` flag at the command line (so the
    new runner can be turned on without editing source).

We also verify that every pipeline YAML on disk is reachable through
*some* caller's task-file -> YAML mapping. The mapping convention is
`<dir>/tasks/<name>.json -> <dir>/pipelines/<name>/<name>.yml`, so we
collect the legacy task paths each caller references and assert each
YAML lines up with one of them. Anything missing means the YAML is
orphaned (no caller will ever invoke it), which is what the previous
half-migrated state looked like.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest


REPO = Path(__file__).resolve().parents[2]

CALLERS = [
    REPO / "setup/single-node/scripts/setup-code-server.sh",
    REPO / "setup/single-node/scripts/setup-explorer-wrapper.sh",
    REPO / "samples/voice-image-edit/scripts/deploy-all.sh",
    REPO / "samples/voice-image-edit/app/infra/deploy.sh",
    REPO / "samples/neuron-anatomy/scripts/deploy.sh",
]


def _id(p: Path) -> str:
    return p.relative_to(REPO).as_posix()


@pytest.mark.parametrize("caller", CALLERS, ids=_id)
def test_caller_has_use_pipeline_runner_flag(caller: Path):
    text = caller.read_text(encoding="utf-8")
    assert "--use-pipeline-runner" in text, (
        f"{_id(caller)} does not mention --use-pipeline-runner. Either "
        f"the flag was removed or the caller has not been integrated "
        f"with the new runner yet."
    )


@pytest.mark.parametrize("caller", CALLERS, ids=_id)
def test_caller_sources_dispatch_helper(caller: Path):
    text = caller.read_text(encoding="utf-8")
    # We accept either an explicit `source .../dispatch.sh` line (the
    # default integration shape) or a delegating call to a child caller
    # that itself sources it.
    sources = "tools/pipeline-runner/lib-sh/dispatch.sh" in text
    delegates = (
        "scripts/deploy.sh" in text  # voice-image-edit/scripts/deploy-all.sh delegates
        or "voice-image-edit/app/infra/deploy.sh" in text
        or "samples/neuron-anatomy/scripts/deploy.sh" in text
    )
    assert sources or delegates, (
        f"{_id(caller)} neither sources the dispatch helper directly nor "
        f"delegates to a caller that does. Add a `source "
        f"$REPO_ROOT/tools/pipeline-runner/lib-sh/dispatch.sh` block."
    )


_PIPELINE_NAME_RE = re.compile(r"^name:\s*(\S+)\s*$", re.MULTILINE)


# Pipelines kept on disk but no longer wired to any caller.
# The legacy whisper-precompile and whisper-server orphans were deleted
# together with the JSON retirement in STEP 2. The allowlist is now empty.
_KNOWN_ORPHAN_PIPELINES: dict[str, str] = {}


def _pipelines_on_disk() -> list[Path]:
    out: list[Path] = []
    for d in REPO.glob("**/pipelines/*"):
        if not d.is_dir() or "node_modules" in d.parts:
            continue
        for y in d.glob("*.yml"):
            if y.is_file():
                out.append(y)
    # The runner ships an example pipeline; it is not a deploy target so
    # it does not need a caller.
    out = [p for p in out if "/examples/" not in p.as_posix()]
    # Drop the documented orphans; the dedicated test below pins the
    # allowlist itself so it cannot grow silently.
    return [p for p in out if p.stem not in _KNOWN_ORPHAN_PIPELINES]


def test_known_orphan_list_matches_actual_orphans():
    """The allowlist of orphan pipelines must reflect reality. If a
    pipeline that *is* referenced from a caller appears in the
    allowlist, the allowlist is stale; remove the entry."""
    bad = []
    for name, _reason in _KNOWN_ORPHAN_PIPELINES.items():
        for caller in CALLERS:
            body = caller.read_text(encoding="utf-8")
            if any(m in body for m in (f"{name}.json", f"{name}.yml")):
                bad.append(f"{name}: still referenced by {caller.name}")
                break
    assert not bad, (
        "Pipelines listed as orphans are still referenced. Remove them "
        "from _KNOWN_ORPHAN_PIPELINES:\n  " + "\n  ".join(bad)
    )


@pytest.mark.parametrize("yml", _pipelines_on_disk(), ids=_id)
def test_pipeline_is_reachable_from_a_caller(yml: Path):
    """At least one of the five callers must mention this pipeline's
    legacy task JSON, its YAML, or just its bare filename. We accept the
    bare-filename match because deploy-all.sh / neuron-anatomy/deploy.sh
    construct paths through shell variable expansion (e.g.
    `$QIE_TASKS/qwen-image-edit-prepare.json`)."""
    pipeline_name = yml.stem
    matchers = [
        f"tasks/{pipeline_name}.json",
        f"{pipeline_name}.json",
        f"{pipeline_name}.yml",
    ]
    for caller in CALLERS:
        body = caller.read_text(encoding="utf-8")
        if any(m in body for m in matchers):
            return
    pytest.fail(
        f"No caller in {[c.name for c in CALLERS]} references pipeline "
        f"{pipeline_name!r} (looked for {matchers}). The YAML is on "
        f"disk but nothing will ever invoke it. Either add a step that "
        f"calls run_task_json on tasks/{pipeline_name}.json, or remove "
        f"the orphaned YAML."
    )
