"""Pipeline file loader.

Reads a YAML pipeline file, validates the schema, resolves task script paths
relative to the pipeline file, and returns a typed ``Pipeline`` object.

The schema is intentionally small. Adding a field is cheap; please add a
test in ``tests/`` first so the behaviour stays pinned.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import Optional

import yaml

from durations import parse_duration


# Defaults used when ``defaults:`` is missing or partial.
_DEFAULT_TIMEOUT = "5m"
_DEFAULT_RETRIES = 0
_DEFAULT_RETRY_DELAY = "5s"
_DEFAULT_CW_LOGS = True
_DEFAULT_MAX_CONCURRENCY = 1


class PipelineError(ValueError):
    """Raised when a pipeline file cannot be loaded or validated."""


@dataclass
class Task:
    id: str
    script_path: Path
    timeout_seconds: int
    retries: int
    retry_delay_seconds: int
    needs: list[str] = field(default_factory=list)
    fingerprint_inputs: list[str] = field(default_factory=list)
    cloudwatch_logs: bool = True
    # When true the task is exempt from the fingerprint cache and runs on
    # every invocation. Use for steps whose decision depends on external
    # state that the fingerprint deliberately ignores (e.g. "is the compiled
    # artifact already present on EFS?"). Without this, a step that probed
    # external state once and was cached as success would never re-probe, so
    # a later change in that state (artifacts appearing or vanishing) is
    # silently missed.
    always_run: bool = False


@dataclass
class Pipeline:
    name: str
    description: str
    file: Path
    vars: dict[str, str]
    required_vars: list[str]
    max_concurrency: int
    tasks: list[Task]

    def task_by_id(self, task_id: str) -> Optional[Task]:
        for t in self.tasks:
            if t.id == task_id:
                return t
        return None


def load(path: str | Path) -> Pipeline:
    """Load and validate a YAML pipeline file."""
    file_path = Path(path).resolve()
    if not file_path.is_file():
        raise PipelineError(f"pipeline file not found: {file_path}")

    with file_path.open("r", encoding="utf-8") as f:
        try:
            doc = yaml.safe_load(f)
        except yaml.YAMLError as exc:
            raise PipelineError(f"invalid YAML in {file_path}: {exc}") from exc

    if not isinstance(doc, dict):
        raise PipelineError(f"{file_path}: top-level document must be a mapping")

    name = _require_str(doc, "name", file_path)
    description = str(doc.get("description", "") or "")

    raw_vars = doc.get("vars", {}) or {}
    if not isinstance(raw_vars, dict):
        raise PipelineError(f"{file_path}: 'vars' must be a mapping")
    pipeline_vars: dict[str, str] = {}
    for k, v in raw_vars.items():
        if not isinstance(k, str):
            raise PipelineError(f"{file_path}: var keys must be strings ({k!r})")
        if isinstance(v, bool):
            pipeline_vars[k] = "true" if v else "false"
        elif v is None:
            pipeline_vars[k] = ""
        else:
            pipeline_vars[k] = str(v)

    required_vars_raw = doc.get("required_vars", []) or []
    if not isinstance(required_vars_raw, list):
        raise PipelineError(f"{file_path}: 'required_vars' must be a list")
    required_vars = [str(x) for x in required_vars_raw]

    defaults = doc.get("defaults", {}) or {}
    if not isinstance(defaults, dict):
        raise PipelineError(f"{file_path}: 'defaults' must be a mapping")
    default_timeout = parse_duration(
        defaults.get("timeout", _DEFAULT_TIMEOUT), field="defaults.timeout"
    )
    default_retries = int(defaults.get("retries", _DEFAULT_RETRIES))
    default_retry_delay = parse_duration(
        defaults.get("retry_delay", _DEFAULT_RETRY_DELAY),
        field="defaults.retry_delay",
    )
    default_cw_logs = bool(defaults.get("cloudwatch_logs", _DEFAULT_CW_LOGS))

    max_concurrency = int(doc.get("max_concurrency", _DEFAULT_MAX_CONCURRENCY))
    if max_concurrency < 1:
        raise PipelineError(
            f"{file_path}: max_concurrency must be >= 1, got {max_concurrency}"
        )

    raw_tasks = doc.get("tasks") or []
    if not isinstance(raw_tasks, list) or not raw_tasks:
        raise PipelineError(f"{file_path}: 'tasks' must be a non-empty list")

    tasks: list[Task] = []
    seen_ids: set[str] = set()
    for i, raw in enumerate(raw_tasks):
        if not isinstance(raw, dict):
            raise PipelineError(f"{file_path}: tasks[{i}] must be a mapping")
        task_id = _require_str(raw, "id", file_path, ctx=f"tasks[{i}]")
        if task_id in seen_ids:
            raise PipelineError(f"{file_path}: duplicate task id {task_id!r}")
        seen_ids.add(task_id)

        script_rel = _require_str(raw, "script", file_path, ctx=task_id)
        script_path = (file_path.parent / script_rel).resolve()
        if not script_path.is_file():
            raise PipelineError(
                f"{file_path}: tasks[{task_id}].script not found: {script_path}"
            )

        timeout = parse_duration(
            raw.get("timeout", default_timeout), field=f"{task_id}.timeout"
        )
        retries = int(raw.get("retries", default_retries))
        if retries < 0:
            raise PipelineError(f"{task_id}.retries must be >= 0")
        retry_delay = parse_duration(
            raw.get("retry_delay", default_retry_delay),
            field=f"{task_id}.retry_delay",
        )
        needs_raw = raw.get("needs", []) or []
        if not isinstance(needs_raw, list):
            raise PipelineError(f"{task_id}.needs must be a list")
        needs = [str(x) for x in needs_raw]

        fp_inputs_raw = raw.get("fingerprint_inputs", []) or []
        if not isinstance(fp_inputs_raw, list):
            raise PipelineError(f"{task_id}.fingerprint_inputs must be a list")
        fp_inputs = [str(x) for x in fp_inputs_raw]

        cw_logs = bool(raw.get("cloudwatch_logs", default_cw_logs))
        always_run = bool(raw.get("always_run", False))

        tasks.append(
            Task(
                id=task_id,
                script_path=script_path,
                timeout_seconds=timeout,
                retries=retries,
                retry_delay_seconds=retry_delay,
                needs=needs,
                fingerprint_inputs=fp_inputs,
                cloudwatch_logs=cw_logs,
                always_run=always_run,
            )
        )

    # Validate that all `needs` references resolve.
    for t in tasks:
        for dep in t.needs:
            if dep not in seen_ids:
                raise PipelineError(
                    f"{file_path}: task {t.id!r} needs unknown task {dep!r}"
                )

    _check_no_cycles(tasks)

    return Pipeline(
        name=name,
        description=description,
        file=file_path,
        vars=pipeline_vars,
        required_vars=required_vars,
        max_concurrency=max_concurrency,
        tasks=tasks,
    )


def _require_str(d: dict, key: str, file_path: Path, *, ctx: str = "") -> str:
    if key not in d:
        loc = f"{file_path}{':' + ctx if ctx else ''}"
        raise PipelineError(f"{loc}: missing required field '{key}'")
    val = d[key]
    if not isinstance(val, str) or not val:
        loc = f"{file_path}{':' + ctx if ctx else ''}"
        raise PipelineError(f"{loc}: field '{key}' must be a non-empty string")
    return val


def _check_no_cycles(tasks: list[Task]) -> None:
    """Topological-sort precheck. Raises if the DAG has a cycle."""
    by_id = {t.id: t for t in tasks}
    in_degree = {t.id: 0 for t in tasks}
    for t in tasks:
        for dep in t.needs:
            in_degree[t.id] += 1
    queue = [tid for tid, n in in_degree.items() if n == 0]
    seen = 0
    while queue:
        tid = queue.pop()
        seen += 1
        for t in tasks:
            if tid in t.needs:
                in_degree[t.id] -= 1
                if in_degree[t.id] == 0:
                    queue.append(t.id)
    if seen != len(tasks):
        cycle_ids = [tid for tid, n in in_degree.items() if n > 0]
        raise PipelineError(f"task graph contains a cycle: {sorted(cycle_ids)}")
