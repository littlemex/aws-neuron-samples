"""Repo policy: no `Co-authored-by:` trailers in commit messages.

Every commit on a working branch is attributed to the human author
only. The test scans all commits unique to the current branch (i.e.
not on `main`) and flags any that mention the trailer.

When run on `main` itself the scan finds no commits and passes trivially;
this is intentional so the test does not have to special-case CI.
"""
from __future__ import annotations

import os
import subprocess


def _git(*args: str) -> str:
    res = subprocess.run(
        ["git", *args], capture_output=True, text=True, check=False
    )
    return (res.stdout or "").strip()


def test_no_co_authored_by_in_branch_commits():
    if os.environ.get("SKIP_GIT_TESTS"):
        # Allow CI snapshots that lack a real .git dir to short-circuit.
        return

    # Resolve the upstream / fork point. `main` is our trunk.
    base = _git("rev-parse", "--verify", "main")
    if not base:
        # Branch checkout without main locally; nothing meaningful to scan.
        return

    head = _git("rev-parse", "HEAD")
    if not head or head == base:
        return

    # `git log <base>..HEAD` lists the commits unique to the working branch.
    log = _git("log", f"{base}..HEAD", "--pretty=%H%n%B%n--END--")
    if not log:
        return

    bad: list[str] = []
    blocks = log.split("--END--")
    for block in blocks:
        block = block.strip()
        if not block:
            continue
        lines = block.splitlines()
        if not lines:
            continue
        sha = lines[0]
        body = "\n".join(lines[1:])
        # A real Git trailer starts the line with `Co-authored-by:`. Only
        # those count as policy violations; the substring may appear in
        # body prose (test descriptions, README excerpts) without harm.
        for raw in body.splitlines():
            stripped = raw.lstrip()
            if stripped.lower().startswith("co-authored-by:"):
                bad.append(f"{sha[:12]}: {raw.strip()}")

    assert not bad, (
        "Found `Co-authored-by:` trailers on the working branch. The repo "
        "policy is to attribute commits to the human author only. Remove "
        "these trailers (e.g. via `git commit --amend` or an interactive "
        "rebase + edit):\n  " + "\n  ".join(bad)
    )
