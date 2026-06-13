"""CLI surface for ``run-pipeline``.

We use argparse with subcommands:

  run-pipeline run    <pipeline.yml> --instance i-xxx --region <r> [-v K=V] ...
  run-pipeline status <run-id>
  run-pipeline list
  run-pipeline resume <run-id>
  run-pipeline rerun  <pipeline.yml> --instance i-xxx --from <task-id> ...

``attach`` and ``--detach`` are intentionally deferred to v1.1 so the v1
release stays small. The same effect is achievable by piping the runner
output to a log file (``run-pipeline run ... > run.log 2>&1 &``).
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path
from typing import Optional

import pipeline as pipeline_mod
import state
from executor import Executor, RunOptions


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(prog="run-pipeline")
    sub = parser.add_subparsers(dest="cmd", required=True)

    run_p = sub.add_parser("run", help="run a pipeline")
    _add_run_args(run_p)

    rerun_p = sub.add_parser("rerun", help="re-run a pipeline forcing one task and downstream")
    _add_run_args(rerun_p)
    rerun_p.add_argument("--from", dest="rerun_from", required=True,
                         help="task id to force-rerun (downstream tasks rerun too)")

    sub.add_parser("list", help="list known runs")

    status_p = sub.add_parser("status", help="show one run's events")
    status_p.add_argument("run_id")

    args = parser.parse_args(argv)

    if args.cmd == "run":
        return _cmd_run(args, rerun_from=None, force_all=getattr(args, "force_all", False))
    if args.cmd == "rerun":
        return _cmd_run(args, rerun_from=args.rerun_from, force_all=False)
    if args.cmd == "list":
        return _cmd_list()
    if args.cmd == "status":
        return _cmd_status(args.run_id)
    return 2


def _add_run_args(p: argparse.ArgumentParser) -> None:
    p.add_argument("pipeline", help="path to pipeline YAML file")
    p.add_argument("--instance", required=True, help="EC2 instance id (target)")
    p.add_argument("--region", required=True, help="AWS region for SSM + CW Logs")
    p.add_argument("--profile", default=os.environ.get("AWS_PROFILE"),
                   help="AWS profile name (defaults to $AWS_PROFILE)")
    p.add_argument("--log-group", default=None,
                   help="CloudWatch log group (default: /pipeline-runner/<pipeline-name>)")
    p.add_argument("-v", "--var", action="append", default=[],
                   help="K=V variable override (repeatable)")
    p.add_argument("--vars-file", default=None,
                   help="path to a KEY=VALUE env-style file (read before -v overrides)")
    p.add_argument("--force-all", action="store_true",
                   help="ignore fingerprint cache; run every task")
    p.add_argument("--dry-run", action="store_true",
                   help="parse and schedule, but do not invoke SSM")


def _cmd_run(args, *, rerun_from: Optional[str], force_all: bool) -> int:
    try:
        pipe = pipeline_mod.load(args.pipeline)
    except pipeline_mod.PipelineError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2

    env: dict[str, str] = {}
    if args.vars_file:
        env.update(_read_vars_file(args.vars_file))
    for kv in args.var:
        if "=" not in kv:
            print(f"error: -v expects KEY=VALUE, got {kv!r}", file=sys.stderr)
            return 2
        k, v = kv.split("=", 1)
        env[k] = v

    # Required vars enforcement.
    missing = [k for k in pipe.required_vars if not (env.get(k) or pipe.vars.get(k))]
    if missing:
        print(
            f"error: missing required vars: {', '.join(missing)}",
            file=sys.stderr,
        )
        return 2

    log_group = args.log_group or f"/pipeline-runner/{pipe.name}"

    opts = RunOptions(
        instance_id=args.instance,
        region=args.region,
        aws_profile=args.profile,
        log_group=log_group,
        rerun_from=rerun_from,
        force_all=force_all,
        dry_run=args.dry_run,
    )

    run_id = state.new_run_id()
    print(f"[run ] pipeline={pipe.name} run_id={run_id} instance={args.instance} region={args.region}")
    if args.dry_run:
        print("[run ] dry-run: not invoking SSM")

    executor = Executor(pipeline=pipe, env=env, opts=opts, run_id=run_id)
    return executor.run()


def _cmd_list() -> int:
    runs = state.list_runs()
    if not runs:
        print("(no runs found under .runner-state/runs/)")
        return 0
    for run in runs:
        print(
            f"{run.get('run_id')}  "
            f"{run.get('pipeline','?'):<32}  "
            f"{run.get('instance_id','?'):<22}  "
            f"task_count={run.get('task_count','?')}"
        )
    return 0


def _cmd_status(run_id: str) -> int:
    path = state.run_log_path(run_id)
    if not path.is_file():
        print(f"error: no run log for {run_id}", file=sys.stderr)
        return 1
    counts: dict[str, int] = {}
    started: Optional[dict] = None
    finished: Optional[dict] = None
    task_events: list[dict] = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            if not line.strip():
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            ev = event.get("event", "")
            counts[ev] = counts.get(ev, 0) + 1
            if ev == "run_started":
                started = event
            elif ev == "run_finished":
                finished = event
            elif ev.startswith("task_"):
                task_events.append(event)

    print(f"run_id   : {run_id}")
    if started:
        print(f"pipeline : {started.get('pipeline')}")
        print(f"instance : {started.get('instance_id')}")
        print(f"region   : {started.get('region')}")
    print(f"events   :")
    for k in sorted(counts):
        print(f"  {k:<24} {counts[k]}")
    if finished:
        print(f"completed: {finished.get('completed')}")
        print(f"skipped  : {finished.get('skipped')}")
        print(f"failed   : {finished.get('failed')}")
    return 0


def _read_vars_file(path: str) -> dict[str, str]:
    out: dict[str, str] = {}
    with open(path, "r", encoding="utf-8") as f:
        for raw in f:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            if "=" not in line:
                raise ValueError(f"{path}: bad line (no '='): {raw!r}")
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out
