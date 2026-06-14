"""Run `bash -n` on every script under any pipelines/**/scripts directory.

Catches: stray syntax errors, unterminated heredocs, unbalanced quotes -
the exact class of bug that the legacy JSON runner happily passed through
because the script body lived in a JSON string literal until SSM
deserialised it.
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

import pytest


REPO = Path(__file__).resolve().parents[2]


def _all_pipeline_scripts() -> list[Path]:
    found: list[Path] = []
    for d in REPO.glob("**/pipelines/*/scripts"):
        if not d.is_dir() or "node_modules" in d.parts:
            continue
        found.extend(sorted(p for p in d.glob("*.sh") if p.is_file()))
    return found


def _id(p: Path) -> str:
    return p.relative_to(REPO).as_posix()


@pytest.mark.parametrize("script", _all_pipeline_scripts(), ids=_id)
def test_bash_n(script: Path):
    if not shutil.which("bash"):
        pytest.skip("bash is not on PATH")
    result = subprocess.run(
        ["bash", "-n", str(script)], capture_output=True, text=True
    )
    assert result.returncode == 0, (
        f"bash -n rejected {script.relative_to(REPO).as_posix()}\n"
        f"stderr:\n{result.stderr}"
    )
