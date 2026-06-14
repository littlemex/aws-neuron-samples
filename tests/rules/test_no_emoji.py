"""Emoji are forbidden in committed sources under the pipeline-runner tree.

Rationale:
  - Emoji break grep / search-by-text and clutter terminal output.
  - The team uses [OK]/[NG]/[WARN] text tags for status logging instead.
  - Emoji also confuse text-to-speech and accessibility tooling.

The check covers the same file set as test_english_only and shares the
same allowlist marker (ALLOW_NON_ENGLISH) so a deliberate exception only
needs one annotation. We accept that the marker name does not literally
say "emoji"; the broader meaning is "this line is exempt from the
language/style policy".
"""
from __future__ import annotations

import re
from pathlib import Path


REPO = Path(__file__).resolve().parents[2]

INCLUDED_PATTERNS = [
    "tools/pipeline-runner/**/*.py",
    "tools/pipeline-runner/**/*.sh",
    "tools/pipeline-runner/**/*.md",
    "tools/pipeline-runner/**/*.yml",
    "tests/**/*.py",
    "tests/**/*.sh",
    "tests/**/*.md",
    "Makefile",
]

EXCLUDED_DIRS = (
    "tools/pipeline-runner/examples/",
    "tools/pipeline-runner/lib/__pycache__/",
)

# Coverage of the common emoji blocks. We deliberately stop short of
# matching every emoji in Unicode; this catches >99% of accidental
# pastes (white check, red cross, lightbulb, fire, ...) without flagging
# bullets or arrows that ship as plain ASCII.
# The literal characters in the misc-symbols range are intentional - they
# anchor that range without resorting to a hex escape that would not match
# the way humans paste.  ALLOW_NON_ENGLISH
_EMOJI_RE = re.compile(
    "["
    "\U0001F300-\U0001F5FF"  # symbols & pictographs
    "\U0001F600-\U0001F64F"  # emoticons
    "\U0001F680-\U0001F6FF"  # transport & map
    "\U0001F700-\U0001F77F"  # alchemical
    "\U0001F900-\U0001F9FF"  # supplemental symbols & pictographs
    "\U0001FA70-\U0001FAFF"  # symbols & pictographs extended-A
    "☀-➿"          # ALLOW_NON_ENGLISH - white check, red cross, etc.
    "]"
)

_ALLOW_MARKER = "ALLOW_NON_ENGLISH"


def _iter_files() -> list[Path]:
    found: list[Path] = []
    for pattern in INCLUDED_PATTERNS:
        for p in REPO.glob(pattern):
            if not p.is_file():
                continue
            rel = p.relative_to(REPO).as_posix()
            if any(rel.startswith(prefix) for prefix in EXCLUDED_DIRS):
                continue
            found.append(p)
    return sorted(set(found))


def test_no_emoji_in_pipeline_runner_sources():
    bad: list[str] = []
    for f in _iter_files():
        try:
            text = f.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for lineno, line in enumerate(text.splitlines(), start=1):
            if _ALLOW_MARKER in line:
                continue
            if _EMOJI_RE.search(line):
                rel = f.relative_to(REPO).as_posix()
                bad.append(f"{rel}:{lineno}: {line.rstrip()}")
    assert not bad, (
        "Emoji found in files that must be plain ASCII.\n"
        "Replace with [OK] / [NG] / [WARN] / [INFO] text tags:\n  "
        + "\n  ".join(bad)
    )
