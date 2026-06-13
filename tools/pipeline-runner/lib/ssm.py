"""SSM Run Command driver.

Wraps ``aws ssm send-command`` + ``get-command-invocation`` and the matching
CloudWatch Logs tail. The runner shells out to the ``aws`` CLI rather than
using boto3 so the runtime dependency is just Python + the AWS CLI that is
already required for SSM access.
"""
from __future__ import annotations

import json
import subprocess
import time
from dataclasses import dataclass
from typing import Iterator, Optional


# Polled command invocation status -> classification.
_TERMINAL_OK = {"Success"}
_TERMINAL_FAIL = {"Failed", "Cancelled", "TimedOut"}


@dataclass
class CommandHandle:
    command_id: str
    instance_id: str
    region: str
    cw_log_group: Optional[str] = None
    cw_log_stream: Optional[str] = None


@dataclass
class CommandResult:
    status: str  # "Success" | "Failed" | "Cancelled" | "TimedOut" | "Timeout"
    exit_code: Optional[int]
    standard_output: str
    standard_error: str


class SsmError(RuntimeError):
    """Raised for fatal SSM API failures (not for task-level failures)."""


def send_command(
    *,
    instance_id: str,
    region: str,
    script: str,
    timeout_seconds: int,
    log_group: Optional[str] = None,
    log_stream_prefix: Optional[str] = None,
    aws_profile: Optional[str] = None,
) -> CommandHandle:
    """Submit a single ``AWS-RunShellScript`` invocation."""
    params: dict = {
        "InstanceIds": [instance_id],
        "DocumentName": "AWS-RunShellScript",
        "TimeoutSeconds": min(max(timeout_seconds, 30), 172800),
        "Parameters": {"commands": [script]},
    }

    if log_group:
        cw_cfg: dict = {
            "CloudWatchLogGroupName": log_group,
            "CloudWatchOutputEnabled": True,
        }
        params["CloudWatchOutputConfig"] = cw_cfg

    cmd = ["aws", "ssm", "send-command", "--region", region]
    if aws_profile:
        cmd += ["--profile", aws_profile]
    cmd += ["--cli-input-json", json.dumps(params), "--output", "json"]

    completed = subprocess.run(cmd, capture_output=True, text=True)
    if completed.returncode != 0:
        raise SsmError(
            f"ssm send-command failed (rc={completed.returncode}): {completed.stderr.strip()}"
        )

    payload = json.loads(completed.stdout)
    command_id = payload["Command"]["CommandId"]

    log_stream = None
    if log_group:
        # SSM names the CloudWatch stream "<commandId>/<instanceId>/<DocumentName>/stdout".
        # We mirror that here so callers can tail without an extra API hop.
        log_stream = f"{command_id}/{instance_id}/aws-runShellScript/stdout"

    return CommandHandle(
        command_id=command_id,
        instance_id=instance_id,
        region=region,
        cw_log_group=log_group,
        cw_log_stream=log_stream,
    )


def cancel(handle: CommandHandle, *, aws_profile: Optional[str] = None) -> None:
    """Best-effort cancel; we ignore failure (the command may already be done)."""
    cmd = [
        "aws", "ssm", "cancel-command",
        "--command-id", handle.command_id,
        "--instance-ids", handle.instance_id,
        "--region", handle.region,
    ]
    if aws_profile:
        cmd += ["--profile", aws_profile]
    subprocess.run(cmd, capture_output=True, text=True)


def wait(
    handle: CommandHandle,
    *,
    timeout_seconds: int,
    poll_interval_seconds: float = 5.0,
    aws_profile: Optional[str] = None,
    on_status: Optional[callable] = None,
) -> CommandResult:
    """Poll until the command terminates or the local watchdog fires."""
    deadline = time.monotonic() + timeout_seconds
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            cancel(handle, aws_profile=aws_profile)
            return CommandResult(
                status="Timeout",
                exit_code=None,
                standard_output="",
                standard_error=f"local watchdog fired after {timeout_seconds}s",
            )

        time.sleep(min(poll_interval_seconds, max(remaining, 1)))

        cmd = [
            "aws", "ssm", "get-command-invocation",
            "--command-id", handle.command_id,
            "--instance-id", handle.instance_id,
            "--region", handle.region,
            "--output", "json",
        ]
        if aws_profile:
            cmd += ["--profile", aws_profile]
        completed = subprocess.run(cmd, capture_output=True, text=True)
        if completed.returncode != 0:
            # Transient failures (e.g. command not yet propagated) keep us in
            # the loop. Surface only persistent failures by waiting them out.
            continue
        invocation = json.loads(completed.stdout)
        status = invocation.get("Status", "Pending")
        if on_status is not None:
            on_status(status)
        if status in _TERMINAL_OK or status in _TERMINAL_FAIL:
            return CommandResult(
                status=status,
                exit_code=invocation.get("ResponseCode"),
                standard_output=invocation.get("StandardOutputContent", "") or "",
                standard_error=invocation.get("StandardErrorContent", "") or "",
            )


def tail_logs(
    *,
    log_group: str,
    log_stream: str,
    region: str,
    stop_predicate: callable,
    aws_profile: Optional[str] = None,
    poll_interval_seconds: float = 2.0,
) -> Iterator[str]:
    """Yield log events from ``log_stream`` until ``stop_predicate()`` is true.

    We use ``aws logs get-log-events`` repeatedly with a forward token so that
    we get the full body even after the command finishes (avoiding the SSM
    24 KB ``StandardOutputContent`` cap).
    """
    next_token: Optional[str] = None
    seen_any = False
    last_seen_at = time.monotonic()
    while True:
        cmd = [
            "aws", "logs", "get-log-events",
            "--log-group-name", log_group,
            "--log-stream-name", log_stream,
            "--region", region,
            "--start-from-head",
            "--output", "json",
        ]
        if aws_profile:
            cmd += ["--profile", aws_profile]
        if next_token:
            cmd += ["--next-token", next_token]
        completed = subprocess.run(cmd, capture_output=True, text=True)
        if completed.returncode == 0:
            payload = json.loads(completed.stdout)
            events = payload.get("events", [])
            for event in events:
                seen_any = True
                last_seen_at = time.monotonic()
                yield event.get("message", "")
            new_token = payload.get("nextForwardToken")
            if new_token and new_token != next_token:
                next_token = new_token
        # Stop only after the command itself has terminated AND we have
        # drained whatever was waiting in the stream. Give CW a couple of
        # seconds after the command exits to flush any trailing buffer.
        if stop_predicate():
            if seen_any and time.monotonic() - last_seen_at < 2.0:
                # One more poll to drain the tail.
                time.sleep(0.5)
                continue
            return
        time.sleep(poll_interval_seconds)
