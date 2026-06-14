"""Engine layer must not use `os.environ.get(KEY, default)` for config.

The voice-image-edit engines (vlm/edit/asr/tts/generate) reach AWS
services and must fail fast when an env var is missing - silent string
defaults have caused real production incidents (wrong region, stale
model id). The convention is to use `env_required(...)` from
`engines._common.env`.

This test parses the engine source via `ast` to find calls of the form
`os.environ.get(literal, literal_or_callable)` and asserts there are
none in the engines/ tree. `os.environ.get(literal)` (no default) is
allowed: that returns None and forces the caller to handle missing
values explicitly.
"""
from __future__ import annotations

import ast
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]
ENGINES_ROOT = REPO / "samples" / "voice-image-edit" / "app" / "backend" / "api" / "engines"

# Files we explicitly allow to keep `os.environ.get(K, default)`. These are
# either trampoline modules that intentionally fall through to a non-AWS
# default, or are not on the engine config-loading path.
ALLOWLIST = {
    # TLS-keepalive style tuning - the default is harmless if missing.
    "engines/_common/http.py",
}


class _GetWithDefaultFinder(ast.NodeVisitor):
    def __init__(self) -> None:
        self.matches: list[tuple[int, str]] = []

    def visit_Call(self, node: ast.Call) -> None:  # noqa: N802 - ast API
        # Looking for: os.environ.get(KEY, DEFAULT)
        if (
            isinstance(node.func, ast.Attribute)
            and node.func.attr == "get"
            and isinstance(node.func.value, ast.Attribute)
            and node.func.value.attr == "environ"
            and isinstance(node.func.value.value, ast.Name)
            and node.func.value.value.id == "os"
            and len(node.args) >= 2
        ):
            key_node = node.args[0]
            key = (
                key_node.value
                if isinstance(key_node, ast.Constant) and isinstance(key_node.value, str)
                else "<dynamic>"
            )
            self.matches.append((node.lineno, key))
        self.generic_visit(node)


def test_engines_do_not_use_environ_get_with_default():
    if not ENGINES_ROOT.is_dir():
        # Repo layout shifted; better to fail loud than silently skip.
        raise AssertionError(f"engine path not found: {ENGINES_ROOT}")

    bad: list[str] = []
    for py in sorted(ENGINES_ROOT.rglob("*.py")):
        rel = py.relative_to(ENGINES_ROOT.parent).as_posix()
        if rel in ALLOWLIST:
            continue
        try:
            tree = ast.parse(py.read_text(encoding="utf-8"))
        except SyntaxError as exc:
            raise AssertionError(f"failed to parse {rel}: {exc}") from exc
        finder = _GetWithDefaultFinder()
        finder.visit(tree)
        for lineno, key in finder.matches:
            bad.append(f"{rel}:{lineno}: os.environ.get({key!r}, ...)")

    assert not bad, (
        "Engine code uses os.environ.get(KEY, default). Replace with "
        "env_required(KEY) from engines._common.env so the service fails "
        "fast on missing config:\n  " + "\n  ".join(bad)
    )
