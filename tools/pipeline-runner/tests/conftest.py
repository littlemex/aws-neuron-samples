"""Test fixtures shared across the runner unit tests.

The runner is not a packaged distribution; bin/run-pipeline puts lib/
on sys.path at startup. Tests do the same trick here so the test files
can import lib modules with bare names ("import durations").
"""
from __future__ import annotations

import sys
from pathlib import Path

_HERE = Path(__file__).resolve().parent
_LIB = _HERE.parent / "lib"
if str(_LIB) not in sys.path:
    sys.path.insert(0, str(_LIB))
