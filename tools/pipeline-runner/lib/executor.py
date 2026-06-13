"""Pipeline executor: schedules and runs tasks against a single EC2 instance.

The scheduler is a small DAG runner with a slot cap (``max_concurrency``).
Tasks become eligible once all their ``needs`` are in a terminal state, and
get scheduled in submission order. We do not try to be clever about
prioritisation.
"""
from __future__ import annotations

import os
import sys
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Optional

import fingerprint
import ssm
from pipeline import Pipeline, Task
from state import TaskRecord, append_run_log, load as load_state, save as save_state


# Terminal SSM statuses that count as "do not retry, do not continue".
_OK = {"Success"}
_FAIL = {"Failed", "Cancelled", "TimedOut", "Timeout"}


@dataclass
class RunOptions:
    instance_id: str
    region: str
    aws_profile: Optional[str]
    log_group: str
    rerun_from: Optional[str] = None
    force_all: bool = False  # ignore fingerprint cache, run everything
    dry_run: bool = False


class Executor:
    def __init__(
        self,
        *,
        pipeline: Pipeline,
        env: dict[str, str],
        opts: RunOptions,
        run_id: str,
    ):
        self.pipeline = pipeline
        self.env = env
        self.opts = opts
        self.run_id = run_id
        self._etag = fingerprint.S3EtagResolver()
        self._state = load_state(pipeline.name, opts.instance_id)
        self._state.setdefault("tasks", {})
        self._lock = threading.Lock()

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def run(self) -> int:
        """Execute the pipeline. Returns process exit code (0 on success)."""
        force_ids = self._compute_force_set()
        completed: set[str] = set()
        skipped: set[str] = set()
        failed: set[str] = set()
        running: dict[str, threading.Thread] = {}

        with append_run_log(self.run_id) as emit:
            emit({
                "event": "run_started",
                "run_id": self.run_id,
                "pipeline": self.pipeline.name,
                "instance_id": self.opts.instance_id,
                "region": self.opts.region,
                "task_count": len(self.pipeline.tasks),
            })

            tasks_by_id = {t.id: t for t in self.pipeline.tasks}
            pending = list(self.pipeline.tasks)

            try:
                while pending or running:
                    # Reap finished threads.
                    for tid in list(running):
                        if not running[tid].is_alive():
                            running[tid].join()
                            del running[tid]

                    # Schedule new tasks while we have free slots.
                    while (
                        len(running) < self.pipeline.max_concurrency
                        and not failed
                    ):
                        next_task = self._pick_next(
                            pending=pending,
                            completed=completed | skipped,
                            running=set(running),
                            failed=failed,
                        )
                        if next_task is None:
                            break
                        pending.remove(next_task)

                        if self._can_skip(next_task, force_ids):
                            skipped.add(next_task.id)
                            self._log_skip(emit, next_task)
                            continue

                        thread = threading.Thread(
                            target=self._run_one_thread,
                            args=(next_task, emit, completed, failed),
                            name=f"task-{next_task.id}",
                            daemon=True,
                        )
                        running[next_task.id] = thread
                        thread.start()

                    if not running and not pending:
                        break

                    if failed and not running:
                        break

                    time.sleep(0.5)
            finally:
                # Persist state even on Ctrl-C.
                save_state(self.pipeline.name, self.opts.instance_id, self._state)

            emit({
                "event": "run_finished",
                "run_id": self.run_id,
                "completed": sorted(completed),
                "skipped": sorted(skipped),
                "failed": sorted(failed),
            })

        # Print the human-friendly summary.
        total = len(self.pipeline.tasks)
        not_run = total - len(completed) - len(skipped) - len(failed)
        print()
        print(f"== Pipeline {self.pipeline.name} ==")
        print(f"  Run id     : {self.run_id}")
        print(f"  Completed  : {len(completed)}")
        print(f"  Skipped    : {len(skipped)}  (cache hit)")
        print(f"  Failed     : {len(failed)}")
        if not_run:
            print(f"  Not run    : {not_run}  (skipped due to upstream failure)")
        print(f"  State file : {self.pipeline.name}/{self.opts.instance_id}.json")
        return 0 if not failed else 1

    # ------------------------------------------------------------------
    # Internals
    # ------------------------------------------------------------------

    def _compute_force_set(self) -> set[str]:
        """Tasks that must run regardless of fingerprint cache.

        ``--force-all`` rebuilds everything. ``--rerun-from <id>`` rebuilds
        the named task plus everything that transitively depends on it.
        """
        if self.opts.force_all:
            return {t.id for t in self.pipeline.tasks}
        if not self.opts.rerun_from:
            return set()
        target = self.opts.rerun_from
        if not self.pipeline.task_by_id(target):
            raise ValueError(f"--rerun-from: unknown task id {target!r}")
        forced: set[str] = set()
        frontier = {target}
        while frontier:
            forced |= frontier
            new_frontier: set[str] = set()
            for t in self.pipeline.tasks:
                if any(dep in forced for dep in t.needs) and t.id not in forced:
                    new_frontier.add(t.id)
            frontier = new_frontier
        return forced

    def _pick_next(
        self,
        *,
        pending: list[Task],
        completed: set[str],
        running: set[str],
        failed: set[str],
    ) -> Optional[Task]:
        for t in pending:
            if any(dep in failed for dep in t.needs):
                continue
            if all(dep in completed for dep in t.needs):
                return t
        return None

    def _can_skip(self, task: Task, force_ids: set[str]) -> bool:
        if task.id in force_ids or self.opts.force_all:
            return False
        prev = (self._state.get("tasks") or {}).get(task.id) or {}
        if prev.get("status") != "success":
            return False
        # Compute fingerprint and compare.
        env = self._env_for(task)
        body = task.script_path.read_bytes()
        parts = fingerprint.compute(
            script_body=body,
            env=env,
            extra_inputs=task.fingerprint_inputs,
            etag_resolver=self._etag,
        )
        if parts.combined() == prev.get("fingerprint"):
            return True
        # Cache miss: stash the diff so the task log can show it later.
        prev["_diff"] = fingerprint.diff(prev, parts)
        return False

    def _env_for(self, task: Task) -> dict[str, str]:
        # Pipeline ``vars`` provide defaults; the merged ``env`` (CLI / file
        # overrides) wins. The script does NOT see runner-internal state.
        merged: dict[str, str] = {}
        merged.update(self.pipeline.vars)
        merged.update(self.env)
        return merged

    def _log_skip(self, emit, task: Task) -> None:
        emit({
            "event": "task_skipped",
            "task_id": task.id,
            "reason": "fingerprint_match",
        })
        print(f"[SKIP ] {task.id} (cache hit)")

    def _run_one_thread(
        self,
        task: Task,
        emit,
        completed: set[str],
        failed: set[str],
    ) -> None:
        try:
            ok = self._run_one(task, emit)
        except Exception as exc:  # noqa: BLE001
            emit({"event": "task_crashed", "task_id": task.id, "error": str(exc)})
            print(f"[CRASH] {task.id}: {exc}", file=sys.stderr)
            with self._lock:
                failed.add(task.id)
            return
        with self._lock:
            if ok:
                completed.add(task.id)
            else:
                failed.add(task.id)

    def _run_one(self, task: Task, emit) -> bool:
        env = self._env_for(task)
        body = task.script_path.read_bytes()
        parts = fingerprint.compute(
            script_body=body,
            env=env,
            extra_inputs=task.fingerprint_inputs,
            etag_resolver=self._etag,
        )

        prev = (self._state.get("tasks") or {}).get(task.id) or {}
        diff = fingerprint.diff(prev, parts) if prev else []

        attempts_allowed = task.retries + 1
        last_result: Optional[ssm.CommandResult] = None
        last_handle: Optional[ssm.CommandHandle] = None

        for attempt in range(1, attempts_allowed + 1):
            if attempt == 1 and diff:
                print(f"[RUN  ] {task.id} (cache invalidated)")
                for line in diff:
                    print(f"        {line}")
            elif attempt == 1:
                print(f"[RUN  ] {task.id}")
            else:
                print(f"[RETRY] {task.id} ({attempt}/{attempts_allowed})")

            emit({
                "event": "task_started",
                "task_id": task.id,
                "attempt": attempt,
                "fingerprint": parts.combined(),
            })

            script = _build_script_with_env(task.script_path, env)

            if self.opts.dry_run:
                print(f"        [DRY-RUN] would invoke {task.script_path.name}")
                self._record_task(task, parts, TaskRecord(
                    status="success",
                    fingerprint=parts.combined(),
                    script_digest=parts.script_digest,

                    inputs_digest=parts.inputs_digest,
                    inputs_resolved=parts.inputs_resolved,
                    started_at=time.time(),
                    finished_at=time.time(),
                    attempts=attempt,
                ))
                emit({"event": "task_finished", "task_id": task.id, "status": "Success", "attempt": attempt, "dry_run": True})
                return True

            log_group = self.opts.log_group if task.cloudwatch_logs else None
            try:
                handle = ssm.send_command(
                    instance_id=self.opts.instance_id,
                    region=self.opts.region,
                    script=script,
                    timeout_seconds=task.timeout_seconds,
                    log_group=log_group,
                    aws_profile=self.opts.aws_profile,
                )
            except ssm.SsmError as exc:
                emit({"event": "task_send_failed", "task_id": task.id, "attempt": attempt, "error": str(exc)})
                print(f"        ssm send-command failed: {exc}", file=sys.stderr)
                if attempt < attempts_allowed:
                    time.sleep(task.retry_delay_seconds)
                    continue
                self._record_task(task, parts, TaskRecord(
                    status="failed",
                    fingerprint=parts.combined(),
                    script_digest=parts.script_digest,

                    inputs_digest=parts.inputs_digest,
                    inputs_resolved=parts.inputs_resolved,
                    started_at=time.time(),
                    finished_at=time.time(),
                    attempts=attempt,
                    error=str(exc),
                ))
                return False

            last_handle = handle
            print(f"        command_id={handle.command_id}")
            if handle.cw_log_stream:
                print(f"        cw_log_stream={handle.cw_log_stream}")
                emit({
                    "event": "task_log_stream",
                    "task_id": task.id,
                    "command_id": handle.command_id,
                    "log_group": handle.cw_log_group,
                    "log_stream": handle.cw_log_stream,
                })

            # Live tail in a daemon thread so we don't block the wait.
            tail_stop = threading.Event()
            tailer: Optional[threading.Thread] = None
            if handle.cw_log_group and handle.cw_log_stream:
                tailer = threading.Thread(
                    target=_tail_logs_to_stdout,
                    args=(
                        handle.cw_log_group,
                        handle.cw_log_stream,
                        handle.region,
                        self.opts.aws_profile,
                        tail_stop,
                        f"{task.id}",
                    ),
                    daemon=True,
                    name=f"tail-{task.id}",
                )
                tailer.start()

            try:
                result = ssm.wait(
                    handle,
                    timeout_seconds=task.timeout_seconds,
                    poll_interval_seconds=5.0,
                    aws_profile=self.opts.aws_profile,
                )
            finally:
                tail_stop.set()
                if tailer:
                    tailer.join(timeout=4.0)

            last_result = result

            if result.status in _OK:
                emit({"event": "task_finished", "task_id": task.id, "status": result.status, "attempt": attempt})
                self._record_task(task, parts, TaskRecord(
                    status="success",
                    fingerprint=parts.combined(),
                    script_digest=parts.script_digest,

                    inputs_digest=parts.inputs_digest,
                    inputs_resolved=parts.inputs_resolved,
                    command_id=handle.command_id,
                    log_stream=handle.cw_log_stream,
                    started_at=time.time(),
                    finished_at=time.time(),
                    attempts=attempt,
                ))
                # Print a tail of stdout when CW Logs were not used.
                if not handle.cw_log_group and result.standard_output:
                    out = result.standard_output.strip()
                    print(_indent(out[-1500:]))
                return True

            emit({
                "event": "task_attempt_failed",
                "task_id": task.id,
                "attempt": attempt,
                "status": result.status,
                "stderr": result.standard_error[-2000:],
            })
            print(f"        attempt failed: {result.status}", file=sys.stderr)
            if result.standard_error:
                print(_indent(result.standard_error[-2000:]), file=sys.stderr)

            if attempt < attempts_allowed:
                time.sleep(task.retry_delay_seconds)

        emit({
            "event": "task_finished",
            "task_id": task.id,
            "status": last_result.status if last_result else "Failed",
            "attempt": attempts_allowed,
        })
        self._record_task(task, parts, TaskRecord(
            status="failed",
            fingerprint=parts.combined(),
            script_digest=parts.script_digest,

            inputs_digest=parts.inputs_digest,
            inputs_resolved=parts.inputs_resolved,
            command_id=last_handle.command_id if last_handle else None,
            log_stream=last_handle.cw_log_stream if last_handle else None,
            started_at=time.time(),
            finished_at=time.time(),
            attempts=attempts_allowed,
            error=last_result.standard_error[-2000:] if last_result else None,
        ))
        return False

    def _record_task(self, task: Task, parts: fingerprint.FingerprintParts, record: TaskRecord) -> None:
        with self._lock:
            self._state.setdefault("tasks", {})[task.id] = record.to_dict()
            self._state["last_run"] = time.time()
            save_state(self.pipeline.name, self.opts.instance_id, self._state)


# ----------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------

def _build_script_with_env(script_path: Path, env: dict[str, str]) -> str:
    """Wrap a bash script so the SSM agent runs it with the right env.

    We use ``env -i`` to start from a clean slate and explicitly pass each
    var; that keeps the SSM-side environment from leaking surprise values
    into the script.
    """
    body = script_path.read_text(encoding="utf-8")

    lines = ["#!/usr/bin/env bash", "set -euo pipefail"]
    for k in sorted(env):
        v = env[k]
        # Single-quote the value, escaping any embedded single quotes.
        escaped = v.replace("'", "'\\''")
        lines.append(f"export {k}='{escaped}'")
    lines.append("")
    lines.append(f"# ----- script body: {script_path.name} -----")
    lines.append(body)
    return "\n".join(lines)


def _indent(text: str, prefix: str = "        ") -> str:
    return "\n".join(f"{prefix}{line}" for line in text.splitlines())


def _tail_logs_to_stdout(
    log_group: str,
    log_stream: str,
    region: str,
    aws_profile: Optional[str],
    stop_event: threading.Event,
    label: str,
) -> None:
    try:
        for line in ssm.tail_logs(
            log_group=log_group,
            log_stream=log_stream,
            region=region,
            stop_predicate=stop_event.is_set,
            aws_profile=aws_profile,
        ):
            for sub in line.rstrip("\n").splitlines():
                print(f"  [{label}] {sub}")
    except Exception as exc:  # noqa: BLE001
        print(f"  [{label}] (log tail error: {exc})", file=sys.stderr)
