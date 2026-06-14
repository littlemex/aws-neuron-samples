"""Unit tests for the YAML loader and DAG validator.

These cover the contracts the rest of the runner relies on:
  - top-level required fields
  - duration parsing wired through `defaults`/`tasks`
  - missing/empty/duplicate task ids are rejected
  - `needs:` references must resolve
  - the DAG must be acyclic
"""
from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

import pipeline as pipeline_mod


def _write(tmp_path: Path, name: str, body: str) -> Path:
    p = tmp_path / name
    p.write_text(textwrap.dedent(body), encoding="utf-8")
    return p


def _scripts_dir(tmp_path: Path) -> Path:
    d = tmp_path / "scripts"
    d.mkdir(exist_ok=True)
    return d


def _touch_script(scripts_dir: Path, name: str) -> None:
    (scripts_dir / name).write_text("#!/usr/bin/env bash\nexit 0\n", encoding="utf-8")


def _minimal_yaml(scripts_dir_name: str = "scripts") -> str:
    return f"""
        name: example
        description: minimal
        defaults:
          timeout: 1m
        tasks:
          - id: only
            script: {scripts_dir_name}/only.sh
    """


def test_loads_minimal_pipeline(tmp_path):
    scripts = _scripts_dir(tmp_path)
    _touch_script(scripts, "only.sh")
    f = _write(tmp_path, "p.yml", _minimal_yaml())
    p = pipeline_mod.load(f)
    assert p.name == "example"
    assert p.tasks[0].id == "only"
    assert p.tasks[0].timeout_seconds == 60
    assert p.max_concurrency == 1


def test_required_vars_split(tmp_path):
    scripts = _scripts_dir(tmp_path)
    _touch_script(scripts, "only.sh")
    f = _write(
        tmp_path,
        "p.yml",
        """
        name: example
        vars:
          A: "1"
        required_vars:
          - B
        tasks:
          - id: only
            script: scripts/only.sh
        """,
    )
    p = pipeline_mod.load(f)
    assert p.vars == {"A": "1"}
    assert p.required_vars == ["B"]


def test_duplicate_task_id_raises(tmp_path):
    scripts = _scripts_dir(tmp_path)
    _touch_script(scripts, "x.sh")
    _touch_script(scripts, "y.sh")
    f = _write(
        tmp_path,
        "p.yml",
        """
        name: dup
        tasks:
          - id: a
            script: scripts/x.sh
          - id: a
            script: scripts/y.sh
        """,
    )
    with pytest.raises(pipeline_mod.PipelineError, match="duplicate"):
        pipeline_mod.load(f)


def test_needs_unknown_task_raises(tmp_path):
    scripts = _scripts_dir(tmp_path)
    _touch_script(scripts, "x.sh")
    f = _write(
        tmp_path,
        "p.yml",
        """
        name: badneed
        tasks:
          - id: a
            script: scripts/x.sh
            needs: [does-not-exist]
        """,
    )
    with pytest.raises(pipeline_mod.PipelineError, match="unknown task"):
        pipeline_mod.load(f)


def test_cycle_in_needs_raises(tmp_path):
    scripts = _scripts_dir(tmp_path)
    for name in ("a.sh", "b.sh"):
        _touch_script(scripts, name)
    f = _write(
        tmp_path,
        "p.yml",
        """
        name: cyclic
        tasks:
          - id: a
            script: scripts/a.sh
            needs: [b]
          - id: b
            script: scripts/b.sh
            needs: [a]
        """,
    )
    with pytest.raises(pipeline_mod.PipelineError, match="cycle"):
        pipeline_mod.load(f)


def test_missing_script_file_raises(tmp_path):
    f = _write(
        tmp_path,
        "p.yml",
        """
        name: missing
        tasks:
          - id: only
            script: scripts/never.sh
        """,
    )
    with pytest.raises(pipeline_mod.PipelineError, match="not found"):
        pipeline_mod.load(f)


def test_max_concurrency_validation(tmp_path):
    scripts = _scripts_dir(tmp_path)
    _touch_script(scripts, "x.sh")
    f = _write(
        tmp_path,
        "p.yml",
        """
        name: bad-concurrency
        max_concurrency: 0
        tasks:
          - id: a
            script: scripts/x.sh
        """,
    )
    with pytest.raises(pipeline_mod.PipelineError, match="max_concurrency"):
        pipeline_mod.load(f)


def test_per_task_timeout_overrides_default(tmp_path):
    scripts = _scripts_dir(tmp_path)
    for name in ("a.sh", "b.sh"):
        _touch_script(scripts, name)
    f = _write(
        tmp_path,
        "p.yml",
        """
        name: timeouts
        defaults:
          timeout: 5m
        tasks:
          - id: short
            timeout: 30s
            script: scripts/a.sh
          - id: long
            timeout: 2h
            script: scripts/b.sh
        """,
    )
    p = pipeline_mod.load(f)
    by_id = {t.id: t for t in p.tasks}
    assert by_id["short"].timeout_seconds == 30
    assert by_id["long"].timeout_seconds == 7200
