#!/usr/bin/env python3
"""Patch upstream Neuron Qwen-Image-Edit compile scripts.

The cleanup pass at the end of every compile_*.py script does:

    data    = dict(load_file(shard_file))           # mmap'd safetensors
    cleaned = {k: v for k, v in data.items() if 'master_weight' not in k}
    cleaned.update(inv_freq_buffers)
    save_file(cleaned, shard_file)                  # rewrites the file

That last line rewrites the file the kernel still has mmap'd via cleaned's
tensor views. As soon as save_file reallocates pages, the views point at
freed memory and serialize_file dies with `Bad address (os error 14)`.

Atomic fix:

    cleaned = {...}
    cleaned.update(inv_freq_buffers)
    cleaned_size = ...
    tmp_file = shard_file + ".tmp"
    save_file(cleaned, tmp_file)        # write to a *different* file (no
                                         # mmap collision)
    del data, cleaned                    # drop refs *before* rename
    gc.collect()
    os.replace(tmp_file, shard_file)     # rename atomically

This patcher is idempotent: it skips files that already use the .tmp +
os.replace pattern. It rewrites the script file in place to keep the
diff minimal.
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

# The exact line we replace. We match leading indentation so we can keep
# it consistent with whatever the upstream script uses.
_SAVE_RE = re.compile(
    r"^(?P<indent>[ \t]+)save_file\(cleaned,\s*shard_file\)\s*$",
    re.MULTILINE,
)

_SENTINEL = "# patched: atomic save (mmap-safe)"


def patch(text: str) -> tuple[str, int]:
    """Return (new_text, n_replacements)."""
    if _SENTINEL in text:
        return text, 0

    # Make sure `os` and `gc` are imported. Other imports (load_file,
    # save_file, dict, ...) are already present.
    new_text = text
    if not re.search(r"^\s*import\s+os\b", new_text, re.MULTILINE):
        new_text = "import os\n" + new_text
    if not re.search(r"^\s*import\s+gc\b", new_text, re.MULTILINE):
        new_text = "import gc\n" + new_text

    def repl(m: re.Match[str]) -> str:
        indent = m.group("indent")
        # NOTE: don't null `cleaned` here — downstream print() uses len(cleaned).
        # del data + gc.collect() is enough to drop the mmap'd source views;
        # cleaned itself is a fresh dict that doesn't share pages with the file.
        lines = [
            f"{indent}{_SENTINEL}",
            f'{indent}_tmp_file = shard_file + ".tmp"',
            f"{indent}save_file(cleaned, _tmp_file)",
            f"{indent}try:",
            f"{indent}    del data",
            f"{indent}except Exception:",
            f"{indent}    pass",
            f"{indent}gc.collect()",
            f"{indent}os.replace(_tmp_file, shard_file)",
        ]
        return "\n".join(lines)

    new_text, n = _SAVE_RE.subn(repl, new_text)
    return new_text, n


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument(
        "files",
        nargs="+",
        help="paths to compile_*.py scripts to patch in place",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="print would-be changes without writing",
    )
    args = p.parse_args()

    failed = 0
    for raw in args.files:
        path = Path(raw)
        if not path.exists():
            print(f"[SKIP] {path}: not found", file=sys.stderr)
            failed += 1
            continue
        text = path.read_text()
        new_text, n = patch(text)
        if n == 0 and _SENTINEL in text:
            print(f"[SKIP] {path}: already patched")
            continue
        if n == 0:
            print(f"[SKIP] {path}: no save_file(cleaned, shard_file) match")
            continue
        if args.dry_run:
            print(f"[DRY] {path}: would patch {n} site(s)")
            continue
        backup = path.with_suffix(path.suffix + ".orig")
        if not backup.exists():
            backup.write_text(text)
        path.write_text(new_text)
        print(f"[OK]  {path}: patched {n} site(s) (backup -> {backup})")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
