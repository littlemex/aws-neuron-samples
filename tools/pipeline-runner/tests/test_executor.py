"""Smoke tests for the executor through the dry-run path.

The dry-run does not invoke SSM and does not need real AWS access. We
build a tiny pipeline on disk and exercise the scheduler:

  - DAG order is honoured (children only run after parents)
  - Cache hit: a second run with the same inputs skips every task
  - Force-all: --force-all rebuilds every task even when cached
  - Rerun-from: forces the named task and every transitively dependent
    task, but leaves earlier tasks cached
"""
from __future__ import annotations

import textwrap
from pathlib import Path

import pytest

import pipeline as pipeline_mod
from executor import Executor, RunOptions


def _write_pipeline(tmp_path: Path) -> Path:
    scripts = tmp_path / "scripts"
    scripts.mkdir()
    (scripts / "a.sh").write_text("#!/usr/bin/env bash\necho a\n")
    (scripts / "b.sh").write_text("#!/usr/bin/env bash\necho b\n")
    (scripts / "c.sh").write_text("#!/usr/bin/env bash\necho c\n")

    yml = tmp_path / "p.yml"
    yml.write_text(
        textwrap.dedent(
            """
            name: linear
            defaults:
              cloudwatch_logs: false
            tasks:
              - id: a
                script: scripts/a.sh
              - id: b
                script: scripts/b.sh
                needs: [a]
              - id: c
                script: scripts/c.sh
                needs: [b]
                fingerprint_inputs:
                  - "{{C_INPUT}}"
            """
        ).strip()
    )
    return yml


@pytest.fixture
def cwd_in(tmp_path: Path, monkeypatch):
    monkeypatch.chdir(tmp_path)
    return tmp_path


def _run(yml: Path, *, env: dict[str, str], force_all: bool = False, rerun_from: str | None = None) -> int:
    p = pipeline_mod.load(yml)
    opts = RunOptions(
        instance_id="i-test",
        region="us-east-2",
        aws_profile=None,
        log_group="/test/log",
        rerun_from=rerun_from,
        force_all=force_all,
        dry_run=True,
    )
    import state as state_mod  # local import so the cwd_in fixture is in effect
    rid = state_mod.new_run_id()
    return Executor(pipeline=p, env=env, opts=opts, run_id=rid).run()


def test_first_run_executes_all_tasks(cwd_in: Path):
    yml = _write_pipeline(cwd_in)
    assert _run(yml, env={"C_INPUT": "v1"}) == 0

    import state as state_mod
    s = state_mod.load("linear", "i-test")
    assert set(s["tasks"].keys()) == {"a", "b", "c"}
    assert all(t["status"] == "success" for t in s["tasks"].values())


def test_second_run_is_fully_cached(cwd_in: Path, capsys):
    yml = _write_pipeline(cwd_in)
    _run(yml, env={"C_INPUT": "v1"})
    capsys.readouterr()

    rc = _run(yml, env={"C_INPUT": "v1"})
    out = capsys.readouterr().out
    assert rc == 0
    assert out.count("[SKIP ]") == 3


def test_force_all_busts_cache(cwd_in: Path, capsys):
    yml = _write_pipeline(cwd_in)
    _run(yml, env={"C_INPUT": "v1"})
    capsys.readouterr()

    rc = _run(yml, env={"C_INPUT": "v1"}, force_all=True)
    out = capsys.readouterr().out
    assert rc == 0
    # Every task ran; nothing was skipped.
    assert "[SKIP " not in out
    assert out.count("[RUN  ]") == 3


def test_rerun_from_only_reruns_target_and_descendants(cwd_in: Path, capsys):
    yml = _write_pipeline(cwd_in)
    _run(yml, env={"C_INPUT": "v1"})
    capsys.readouterr()

    rc = _run(yml, env={"C_INPUT": "v1"}, rerun_from="b")
    out = capsys.readouterr().out
    assert rc == 0
    # `a` is upstream of `b`, so it skips. `b` and `c` re-run.
    assert "[SKIP ] a" in out
    assert "[RUN  ] b" in out
    assert "[RUN  ] c" in out


def test_changing_fingerprint_input_reruns_only_that_task(cwd_in: Path, capsys):
    yml = _write_pipeline(cwd_in)
    _run(yml, env={"C_INPUT": "v1"})
    capsys.readouterr()

    rc = _run(yml, env={"C_INPUT": "v2"})
    out = capsys.readouterr().out
    assert rc == 0
    # Only `c` declared C_INPUT in its fingerprint_inputs; `a` and `b`
    # don't depend on it, so the env change must not cascade.
    assert "[SKIP ] a" in out
    assert "[SKIP ] b" in out
    assert "[RUN  ] c" in out


def test_changing_unrelated_env_does_not_invalidate(cwd_in: Path, capsys):
    """Regression guard: an env change that is NOT in any task's
    fingerprint_inputs must NOT bust the cache. The earlier runner used
    to invalidate the entire pipeline on any env change."""
    yml = _write_pipeline(cwd_in)
    _run(yml, env={"C_INPUT": "v1"})
    capsys.readouterr()

    rc = _run(yml, env={"C_INPUT": "v1", "UNRELATED": "anything"})
    out = capsys.readouterr().out
    assert rc == 0
    assert out.count("[SKIP ]") == 3
