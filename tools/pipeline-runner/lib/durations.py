"""Human-readable duration parsing.

We accept the same forms Go and systemd accept, but only the suffixes we
actually use in pipeline YAML files: ``s``, ``m``, ``h``. ``30s`` becomes
``30``, ``5m`` becomes ``300``, ``2h`` becomes ``7200``. Bare integers are
also accepted and treated as seconds, so older configs keep working.
"""
from __future__ import annotations


_UNITS = {"s": 1, "m": 60, "h": 3600}


def parse_duration(value: object, *, field: str = "duration") -> int:
    """Return the number of seconds represented by ``value``.

    Raises ``ValueError`` with a descriptive message for invalid input.
    """
    if value is None:
        raise ValueError(f"{field}: missing value")
    if isinstance(value, bool):
        raise ValueError(f"{field}: bool is not a duration")
    if isinstance(value, int):
        if value < 0:
            raise ValueError(f"{field}: negative duration {value!r}")
        return value
    if not isinstance(value, str):
        raise ValueError(f"{field}: must be string or int, got {type(value).__name__}")

    text = value.strip().lower()
    if not text:
        raise ValueError(f"{field}: empty value")

    if text.isdigit():
        return int(text)

    suffix = text[-1]
    if suffix not in _UNITS:
        raise ValueError(
            f"{field}: unknown duration suffix in {value!r} (use s/m/h or bare seconds)"
        )
    head = text[:-1]
    if not head.isdigit():
        raise ValueError(f"{field}: invalid duration {value!r}")
    return int(head) * _UNITS[suffix]


def format_duration(seconds: int) -> str:
    """Render seconds back as the most compact ``Ns``/``Nm``/``Nh`` form."""
    if seconds < 0:
        return f"{seconds}s"
    if seconds % 3600 == 0 and seconds >= 3600:
        return f"{seconds // 3600}h"
    if seconds % 60 == 0 and seconds >= 60:
        return f"{seconds // 60}m"
    return f"{seconds}s"
