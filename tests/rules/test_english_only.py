"""English-only policy enforcement.

The pipeline-runner subtree (tools/pipeline-runner/, tests/, the root
Makefile, root README.md, and any new pipeline runner consumer code)
must be written in English. The rest of the repository carries history
where mixed-language comments and Japanese descriptions were intentional;
those paths are explicitly excluded so this test only fences the new
surface area.

Enforcement strategy:
  - For each tracked file under the include list, scan every line.
  - A line is considered "Japanese" if it contains at least one CJK
    code point in the ranges below. We are deliberately strict and treat
    any single CJK character as a violation; allowlisted edge cases are
    handled through the explicit allowlist below.
  - Lines containing an "ALLOW_NON_ENGLISH" marker pass through. Use this
    sparingly (e.g. literal user-facing strings that have to be Japanese).

The motivation is operational: text-to-speech reads Japanese characters
as their kanji name when surrounded by English ("u-ni-ko-do-po-i-n-to"),
and grep/search tooling around the runner expects English keywords.
"""
from __future__ import annotations

import re
from pathlib import Path

import pytest


REPO = Path(__file__).resolve().parents[2]

# Files that MUST be English-only. Globs are resolved relative to REPO.
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

# Files explicitly OUT of scope. The runner never edits these so we don't
# enforce English on them; their existing comments and descriptions stay
# Japanese on purpose.
EXCLUDED_DIRS = (
    "tools/pipeline-runner/examples/",  # Example pipelines may carry whatever
    "tools/pipeline-runner/lib/__pycache__/",
)

# CJK Unified Ideographs + Hiragana + Katakana + halfwidth Katakana.
# Full-width punctuation is intentionally NOT in this set; flagging
# punctuation alone produces too much noise for the value.
# The character class below MUST contain CJK code points; that's the
# point of the test. Mark the line so the test exempts itself.
_CJK_RE = re.compile(
    r"[぀-ゟ゠-ヿ一-鿿ｦ-ﾟ]"  # ALLOW_NON_ENGLISH
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
    # Deterministic ordering keeps the test output diffable.
    return sorted(set(found))


def _violations_for(path: Path) -> list[tuple[int, str]]:
    out: list[tuple[int, str]] = []
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        # Binary file slipped into a glob; skip silently.
        return out
    for lineno, line in enumerate(text.splitlines(), start=1):
        if _ALLOW_MARKER in line:
            continue
        if _CJK_RE.search(line):
            out.append((lineno, line.rstrip()))
    return out


def test_pipeline_runner_sources_are_english_only():
    files = _iter_files()
    assert files, (
        "english_only check found no files to scan; INCLUDED_PATTERNS may be "
        "out of date relative to the repo layout"
    )
    bad: list[str] = []
    for f in files:
        violations = _violations_for(f)
        if not violations:
            continue
        rel = f.relative_to(REPO).as_posix()
        for lineno, line in violations[:3]:  # cap to keep failure output readable
            bad.append(f"{rel}:{lineno}: {line}")
        if len(violations) > 3:
            bad.append(f"{rel}: ... and {len(violations) - 3} more line(s)")

    assert not bad, (
        "Non-English text found in files that must be English-only.\n"
        "Add the 'ALLOW_NON_ENGLISH' marker to a specific line if it has\n"
        "to stay non-English (e.g. a user-facing literal). Otherwise, fix\n"
        "the comment / docstring / message:\n  "
        + "\n  ".join(bad)
    )


# Patterns we expect to match real files today; other patterns are
# allowed to be empty so the policy keeps working as the repo grows
# (e.g. tests/**/*.sh has no .sh test scripts yet).
_REQUIRE_NONEMPTY = {
    "tools/pipeline-runner/**/*.py",
    "tools/pipeline-runner/**/*.md",
    "tools/pipeline-runner/**/*.yml",
    "tests/**/*.py",
    "tests/**/*.md",
}


@pytest.mark.parametrize("pattern", INCLUDED_PATTERNS)
def test_glob_resolves(pattern):
    """Sanity check: globs in the required-nonempty set must match at
    least one real file. Without this, refactors that move code can
    silently turn the policy into a no-op."""
    matches = list(REPO.glob(pattern))
    if pattern not in _REQUIRE_NONEMPTY:
        return  # ok to be empty for now
    assert matches, f"glob {pattern!r} matched no files; update INCLUDED_PATTERNS"
