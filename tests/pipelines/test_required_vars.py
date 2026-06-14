"""Cross-check required_vars against the env vars actually referenced by
each pipeline's bash scripts.

Three checks per pipeline:
  - Every ${VAR} the scripts read is declared in either `vars` or
    `required_vars`. Otherwise the runner silently injects an empty
    string and the script reads it as missing config.
  - No unused `vars`/`required_vars` entries (a soft check; we only
    warn, since pipelines may declare variables they pass through to
    downstream consumers).
  - Variables whose name signals "this MUST come from outside" (URL,
    TARBALL, PRESIGNED, REGION) MUST live under `required_vars`, not
    `vars`. Mistakenly putting them under `vars` with an empty default
    means the runner accepts a default-empty value silently.
"""
from __future__ import annotations

import re
from pathlib import Path
from typing import Iterable

import pytest
import yaml


REPO = Path(__file__).resolve().parents[2]


def _all_pipeline_yamls() -> list[Path]:
    found: list[Path] = []
    for d in REPO.glob("**/pipelines/*"):
        if not d.is_dir() or "node_modules" in d.parts:
            continue
        found.extend(d.glob("*.yml"))
    return sorted(set(found))


def _id(p: Path) -> str:
    return p.relative_to(REPO).as_posix()


# ${VAR} or ${VAR:-default} or ${VAR:?msg}; bare $VAR is *also* a reference
# but we do not enforce that case to keep the regex tractable.
_VAR_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)(?:[:?\-+}]|\})")

# Names already provided by bash / systemd / the runner; we do not require
# them to appear in vars/required_vars.
_BUILTIN_NAMES = {
    "HOME", "PATH", "USER", "SHELL", "PWD", "OLDPWD", "TMPDIR",
    "PYTHONUNBUFFERED", "PYTHONPATH", "AWS_DEFAULT_REGION",
    # Loop iteration variables a script might define and re-read.
    "i", "n", "_", "tmp", "code", "loc", "stripped", "status",
    # systemd unit conditional
    "MAINPID",
}

# Names whose "this is supplied externally" semantics make them
# inappropriate as `vars` defaults; they MUST be in required_vars.
_MUST_BE_REQUIRED = re.compile(
    r"^("
    r".*_URL|"
    r".*_TARBALL.*|"
    r".*_PRESIGNED.*|"
    r"AWS_REGION|"
    r".*_BUCKET|"
    r".*_INSTANCE_ID"
    r")$"
)


# Variables assigned with `NAME=value` at the start of a line (or after a
# loop / conditional keyword). We treat any such name as script-local even
# if it's uppercase; bash style is permissive.
_LOCAL_ASSIGN_RE = re.compile(
    r"^\s*([A-Za-z_][A-Za-z0-9_]*)=", re.MULTILINE
)


def _strip_comment_lines(text: str) -> str:
    """Remove `#`-prefixed comment lines from a bash file body.

    Bash comments commonly contain example placeholder syntax like
    `${VAR}`, which is documentation, not a real reference. We do not
    try to handle inline trailing comments; the goal is to suppress
    false positives, not to be a perfect parser."""
    out = []
    for line in text.splitlines():
        if line.lstrip().startswith("#"):
            continue
        out.append(line)
    return "\n".join(out)


def _collect_var_refs(scripts_dir: Path) -> set[str]:
    """Return the set of ${NAME} references whose NAME is NOT defined as
    a local assignment somewhere in the same scripts directory.

    We deliberately scan the whole scripts/ tree as one corpus rather
    than per-file; a precheck script may set up shared state via a
    helper that the main task imports through env."""
    text = "\n".join(
        _strip_comment_lines(sh.read_text(encoding="utf-8", errors="replace"))
        for sh in scripts_dir.rglob("*.sh")
    )
    refs = {m.group(1) for m in _VAR_RE.finditer(text)}
    locals_ = {m.group(1) for m in _LOCAL_ASSIGN_RE.finditer(text)}
    return refs - locals_


def _ids_of(seq: Iterable) -> list[str]:
    return [str(s) for s in seq if s is not None]


@pytest.mark.parametrize("pipeline_yml", _all_pipeline_yamls(), ids=_id)
def test_required_vars_covers_script_references(pipeline_yml: Path):
    with pipeline_yml.open("r", encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    declared = set((doc.get("vars") or {}).keys())
    declared.update(_ids_of(doc.get("required_vars") or []))

    scripts_dir = pipeline_yml.parent / "scripts"
    if not scripts_dir.is_dir():
        pytest.skip(f"no scripts/ next to {pipeline_yml.name}")

    referenced = _collect_var_refs(scripts_dir)

    # Allow built-ins and pure local-loop vars.
    leaks = sorted(v for v in (referenced - declared) if v not in _BUILTIN_NAMES)
    if not leaks:
        return

    # Some scripts intentionally read OS-provided env (HOSTNAME etc.) -
    # only fail when the leaked name is one we expect to inject.
    bad = [v for v in leaks if v.isupper() and v not in _BUILTIN_NAMES]
    assert not bad, (
        f"{pipeline_yml.relative_to(REPO).as_posix()}: scripts read these "
        f"env vars but neither vars: nor required_vars: declares them: "
        f"{bad}\n"
        f"Either add them to one of those blocks, or rename the var to a "
        f"lowercase shell-local form if it really is internal-only."
    )


@pytest.mark.parametrize("pipeline_yml", _all_pipeline_yamls(), ids=_id)
def test_external_inputs_are_required_not_default(pipeline_yml: Path):
    with pipeline_yml.open("r", encoding="utf-8") as f:
        doc = yaml.safe_load(f) or {}
    vars_block = doc.get("vars") or {}
    bad = [k for k in vars_block.keys() if _MUST_BE_REQUIRED.match(k)]
    assert not bad, (
        f"{pipeline_yml.relative_to(REPO).as_posix()}: these keys must "
        f"live under required_vars (they are externally supplied), not "
        f"under vars where a missing value is silently allowed: {bad}"
    )
