"""End-to-end dry-run for every pipeline YAML in the repo.

Each test:
  - loads the YAML
  - synthesises a dummy value for every required_var
  - runs `run-pipeline run --dry-run` against a fake instance
  - asserts the runner exits 0 and prints `[RUN  ]` for every task

This catches: missing scripts, malformed `needs:` chains, type errors in
the YAML, and any future regression in the runner's parser.
"""
from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml


REPO = Path(__file__).resolve().parents[2]
RUNNER = REPO / "tools" / "pipeline-runner" / "bin" / "run-pipeline"


def _all_pipelines() -> list[Path]:
    found: list[Path] = []
    for d in REPO.glob("**/pipelines/*"):
        if not d.is_dir() or "node_modules" in d.parts:
            continue
        for y in d.glob("*.yml"):
            if y.is_file():
                found.append(y)
    # Also include the example pipeline that ships with the runner.
    examples = list(REPO.glob("tools/pipeline-runner/examples/*/*.yml"))
    found.extend(examples)
    return sorted(set(found))


def _id(p: Path) -> str:
    return p.relative_to(REPO).as_posix()


def _dummy_value(key: str) -> str:
    """Pick a plausible dummy for known required-var shapes.

    The dry-run does not hit AWS, but the values still flow through env
    expansion and into ${VAR} substitutions so they have to be at least
    syntactically reasonable.
    """
    upper = key.upper()
    if upper.endswith("_URL") or "URL" in upper:
        return "https://example.invalid/x.tar.gz"
    if upper.endswith("_PORT"):
        return "8801"
    if upper.endswith("_REGION") or upper == "AWS_REGION":
        return "us-east-2"
    if upper.endswith("_BUCKET"):
        return "example-bucket"
    if upper.endswith("_MODEL_ID"):
        return "vendor.model-id-v1:0"
    return "dummy"


@pytest.mark.parametrize("pipeline", _all_pipelines(), ids=_id)
def test_dry_run(pipeline: Path, tmp_path, monkeypatch):
    if not RUNNER.exists():
        pytest.skip(f"runner not found at {RUNNER}")
    if not shutil.which("python3"):
        pytest.skip("python3 not on PATH")

    with pipeline.open("r", encoding="utf-8") as f:
        doc = yaml.safe_load(f)
    required = doc.get("required_vars") or []

    args = [
        sys.executable,
        str(RUNNER),
        "run",
        str(pipeline),
        "--instance",
        "i-deadbeef",
        "--region",
        "us-east-2",
        "--dry-run",
    ]
    for key in required:
        args += ["-v", f"{key}={_dummy_value(key)}"]

    # Run inside a fresh tmp_path so .runner-state from previous tests
    # does not influence cache hit/miss decisions.
    monkeypatch.chdir(tmp_path)
    result = subprocess.run(args, capture_output=True, text=True)
    assert result.returncode == 0, (
        f"dry-run for {pipeline.relative_to(REPO).as_posix()} returned {result.returncode}\n"
        f"stdout:\n{result.stdout}\n"
        f"stderr:\n{result.stderr}"
    )

    # Every task should print `[RUN  ]` exactly once on a fresh state file.
    task_ids = [t["id"] for t in (doc.get("tasks") or [])]
    for tid in task_ids:
        assert f"[RUN  ] {tid}" in result.stdout, (
            f"task {tid} did not run during dry-run; stdout:\n{result.stdout}"
        )
