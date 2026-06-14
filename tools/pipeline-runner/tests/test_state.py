"""Unit tests for the on-disk state files and run-log JSONL.

These cover only behaviour the executor depends on: round-trip of the
state file, append-only semantics for run logs, and recovery of run
metadata from a half-written log.
"""
from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

import state


@pytest.fixture
def cwd_in(tmp_path: Path, monkeypatch):
    """Run each test inside its own tmp dir so .runner-state/ does not
    leak between tests."""
    monkeypatch.chdir(tmp_path)
    return tmp_path


def test_save_and_load_round_trip(cwd_in: Path):
    payload = {
        "tasks": {
            "00-precheck": {
                "status": "success",
                "fingerprint": "deadbeef",
                "script_digest": "ab",
                "inputs_digest": "cd",
                "inputs_resolved": ["x"],
                "command_id": "ssm-1",
                "log_stream": "stream-1",
                "started_at": 1.0,
                "finished_at": 2.0,
                "attempts": 1,
                "error": None,
            }
        },
        "last_run": 2.0,
    }
    state.save("pname", "i-deadbeef", payload)

    out = state.load("pname", "i-deadbeef")
    assert out == payload

    on_disk = cwd_in / ".runner-state" / "pname" / "i-deadbeef.json"
    assert on_disk.is_file()


def test_load_missing_returns_empty(cwd_in: Path):
    out = state.load("never", "i-x")
    assert out == {"tasks": {}, "last_run": None}


def test_run_id_is_short_and_hex(cwd_in: Path):
    rid = state.new_run_id()
    assert len(rid) == 12
    int(rid, 16)  # raises if not hex


def test_run_log_append_emits_one_line_per_event(cwd_in: Path):
    rid = state.new_run_id()
    with state.append_run_log(rid) as emit:
        emit({"event": "run_started", "pipeline": "p", "instance_id": "i", "task_count": 3})
        emit({"event": "task_started", "task_id": "00"})
        emit({"event": "task_finished", "task_id": "00", "status": "Success"})

    log = (cwd_in / ".runner-state" / "runs" / f"{rid}.jsonl").read_text()
    lines = [json.loads(l) for l in log.splitlines() if l.strip()]
    events = [l["event"] for l in lines]
    assert events == ["run_started", "task_started", "task_finished"]
    assert all("ts" in l for l in lines)


def test_find_run_meta_recovers_run_started(cwd_in: Path):
    rid = state.new_run_id()
    with state.append_run_log(rid) as emit:
        emit({"event": "run_started", "pipeline": "demo", "instance_id": "i-x", "task_count": 1})
    meta = state.find_run_meta(rid)
    assert meta is not None
    assert meta["pipeline"] == "demo"
    assert meta["instance_id"] == "i-x"
    assert meta["task_count"] == 1


def test_list_runs_orders_newest_first(cwd_in: Path):
    rids = []
    for _ in range(3):
        rid = state.new_run_id()
        rids.append(rid)
        with state.append_run_log(rid) as emit:
            emit({"event": "run_started", "pipeline": "p", "instance_id": "i", "task_count": 1})
    # Force distinct mtimes so the sort is deterministic.
    runs_dir = cwd_in / ".runner-state" / "runs"
    for i, rid in enumerate(rids):
        os.utime(runs_dir / f"{rid}.jsonl", (1000.0 + i, 1000.0 + i))

    listed = state.list_runs()
    assert [r["run_id"] for r in listed[:3]] == list(reversed(rids))
