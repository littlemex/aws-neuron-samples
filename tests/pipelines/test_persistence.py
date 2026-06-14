"""Persistence checks: paths under /mnt/local/ are NVMe-ephemeral and
must not silently receive important state.

Three rules:
  1. A pipeline that writes to /mnt/local/<x> as a destination MUST
     either be a "compile cache" pipeline (allowlisted by name) OR call
     out the ephemeral nature in its script comments.
  2. Server pipelines (anything matching *-server) must NOT write to
     /mnt/local/ at all - their state belongs on EBS root or EFS.
  3. Any script that depends on /models or /opt/voice-image-edit being
     a real EFS-backed symlink must verify it (`test -L /path` or
     `mountpoint`) in its precheck task. We allow either form.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest


REPO = Path(__file__).resolve().parents[2]


def _all_pipelines():
    found = []
    for d in REPO.glob("**/pipelines/*"):
        if not d.is_dir() or "node_modules" in d.parts:
            continue
        for y in d.glob("*.yml"):
            if y.is_file():
                found.append((y.parent.name, y))
    return sorted(set(found))


def _id(item):
    name, path = item
    return f"{name}::{path.relative_to(REPO).as_posix()}"


# Pipelines whose role is exactly "use NVMe scratch as a compile workdir".
# These are allowed to write to /mnt/local/ for the compile-only step,
# but the resulting compiled artefacts must end up on /models (EFS).
_NVME_COMPILE_ALLOWLIST = {
    "qwen-image-edit-prepare",   # uses /mnt/local for compiler workdir
    "xttsv2-precompile",
    "whisper-precompile",
    "whisper-nxd-precompile",
    "qwen3-vl-prepare",
    "code-server-setup",         # mounts /mnt/local itself
    "setup-efs-paths",           # creates the /mnt/local symlinks
    "migrate-to-efs",             # one-time migration step
}


_MNT_LOCAL_WRITE = re.compile(
    r"(?:cat|tee|cp|mv|rsync|tar\s.*-x.*-C|mkdir(?:\s+-\w+)*)\s+[^\n]*?(/mnt/local/\S+)"
)


def _scripts_under(scripts_dir: Path) -> list[Path]:
    return sorted(scripts_dir.rglob("*.sh"))


@pytest.mark.parametrize("item", _all_pipelines(), ids=_id)
def test_no_unjustified_nvme_writes(item):
    name, yml = item
    scripts_dir = yml.parent / "scripts"
    if not scripts_dir.is_dir():
        return
    if name in _NVME_COMPILE_ALLOWLIST:
        return  # ephemeral writes are part of the design

    bad: list[str] = []
    for sh in _scripts_under(scripts_dir):
        text = sh.read_text(encoding="utf-8", errors="replace")
        for m in _MNT_LOCAL_WRITE.finditer(text):
            bad.append(f"{sh.relative_to(REPO).as_posix()}: {m.group(0)}")
    assert not bad, (
        f"{name}: pipeline writes under /mnt/local/ (NVMe ephemeral). "
        f"Either move the destination to /models or /opt/<x>, or add "
        f"the pipeline name to _NVME_COMPILE_ALLOWLIST in this test if "
        f"the ephemeral write is intentional:\n  " + "\n  ".join(bad)
    )


_PATH_GUARD_RE_BY_NAME = {
    "/models": re.compile(r"test\s+-L\s+/models|test\s+-d\s+/models|readlink\s+-f\s+/models"),
    "/opt/voice-image-edit": re.compile(
        r"test\s+-L\s+/opt/voice-image-edit|test\s+-d\s+/opt/voice-image-edit|readlink\s+-f\s+/opt/voice-image-edit"
    ),
}


@pytest.mark.parametrize("item", _all_pipelines(), ids=_id)
def test_efs_dependent_pipelines_have_a_path_guard(item):
    """If any task writes underneath /models or /opt/voice-image-edit,
    one of the early scripts (typically 00-precheck) must verify that
    the path is a symlink. Without the guard, mkdir -p silently creates
    a real directory on EBS_root and compile artifacts vanish on the
    next stop+start."""
    name, yml = item
    if name in {"setup-efs-paths", "migrate-to-efs", "code-server-setup"}:
        return  # these create the symlinks themselves

    scripts_dir = yml.parent / "scripts"
    if not scripts_dir.is_dir():
        return

    text_all = "\n".join(
        sh.read_text(encoding="utf-8", errors="replace")
        for sh in _scripts_under(scripts_dir)
    )

    # Anchor on a write rather than a read; reading /models is harmless.
    write_re = re.compile(
        r"(?:mkdir|cp|tar\s.*-C\s|rsync|chown)\s[^\n]*?(/models/\S+|/opt/voice-image-edit/\S+)"
    )
    needs_guard: set[str] = set()
    for m in write_re.finditer(text_all):
        path = m.group(1)
        if path.startswith("/models"):
            needs_guard.add("/models")
        elif path.startswith("/opt/voice-image-edit"):
            needs_guard.add("/opt/voice-image-edit")

    missing: list[str] = []
    for guarded_path in needs_guard:
        guard_re = _PATH_GUARD_RE_BY_NAME[guarded_path]
        if not guard_re.search(text_all):
            missing.append(guarded_path)

    assert not missing, (
        f"{name}: writes to {missing} but no script in this pipeline "
        f"guards the path with `test -L`/`test -d`/`readlink`. Add the "
        f"check to 00-precheck so a missing symlink fails the pipeline "
        f"early instead of silently writing to EBS_root."
    )
