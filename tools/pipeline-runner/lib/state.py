"""On-disk state file format for the pipeline runner.

State lives under ``.runner-state/`` at the repository root:

  .runner-state/
    <pipeline-name>/
      <instance-id>.json     # latest fingerprints + status, used for resume
    runs/
      <run-id>.jsonl         # structured per-task event log

The JSON form is intentionally hand-readable so an operator can inspect or
hand-edit it after a partial failure.
"""
from __future__ import annotations

import json
import os
import time
import uuid
from contextlib import contextmanager
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional


@dataclass
class TaskRecord:
    status: str  # "success" | "failed" | "running" | "skipped"
    fingerprint: str
    script_digest: str
    inputs_digest: str
    inputs_resolved: list[str]
    command_id: Optional[str] = None
    log_stream: Optional[str] = None
    started_at: Optional[float] = None
    finished_at: Optional[float] = None
    attempts: int = 1
    error: Optional[str] = None

    def to_dict(self) -> dict[str, Any]:
        return {
            "status": self.status,
            "fingerprint": self.fingerprint,
            "script_digest": self.script_digest,
            "inputs_digest": self.inputs_digest,
            "inputs_resolved": self.inputs_resolved,
            "command_id": self.command_id,
            "log_stream": self.log_stream,
            "started_at": self.started_at,
            "finished_at": self.finished_at,
            "attempts": self.attempts,
            "error": self.error,
        }


def state_root() -> Path:
    """Return the on-disk location of ``.runner-state``.

    We anchor to the current working directory: the runner is meant to be
    invoked from the repository root, and resolving via git is more magic
    than it is worth here.
    """
    return Path.cwd() / ".runner-state"


def state_file_for(pipeline_name: str, instance_id: str) -> Path:
    return state_root() / pipeline_name / f"{instance_id}.json"


def load(pipeline_name: str, instance_id: str) -> dict[str, Any]:
    path = state_file_for(pipeline_name, instance_id)
    if not path.is_file():
        return {"tasks": {}, "last_run": None}
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def save(pipeline_name: str, instance_id: str, state: dict[str, Any]) -> None:
    path = state_file_for(pipeline_name, instance_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
    tmp.replace(path)


def new_run_id() -> str:
    """Short opaque run id used as the run log filename and the CW stream key."""
    return uuid.uuid4().hex[:12]


def run_log_path(run_id: str) -> Path:
    return state_root() / "runs" / f"{run_id}.jsonl"


@contextmanager
def append_run_log(run_id: str):
    path = run_log_path(run_id)
    path.parent.mkdir(parents=True, exist_ok=True)
    f = path.open("a", encoding="utf-8")
    try:
        yield lambda event: _emit(f, event)
    finally:
        f.close()


def _emit(f, event: dict[str, Any]) -> None:
    event = dict(event)
    event.setdefault("ts", time.time())
    f.write(json.dumps(event, ensure_ascii=False) + "\n")
    f.flush()


def find_run_meta(run_id: str) -> Optional[dict[str, Any]]:
    """Read the first ``run_started`` event from a run log, if present."""
    path = run_log_path(run_id)
    if not path.is_file():
        return None
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("event") == "run_started":
                return event
    return None


def list_runs(limit: int = 50) -> list[dict[str, Any]]:
    """Return ``run_started`` events for the most recent runs, newest first."""
    runs_dir = state_root() / "runs"
    if not runs_dir.is_dir():
        return []
    files = sorted(
        (p for p in runs_dir.glob("*.jsonl")),
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    out: list[dict[str, Any]] = []
    for p in files[:limit]:
        meta = find_run_meta(p.stem) or {}
        meta["run_id"] = p.stem
        meta["mtime"] = p.stat().st_mtime
        out.append(meta)
    return out
