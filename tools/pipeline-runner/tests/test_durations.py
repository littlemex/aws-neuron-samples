"""Unit tests for the duration parser.

We accept the same forms as Go and systemd, but only the suffixes the
pipeline YAML actually uses: s, m, h. Bare integers are interpreted as
seconds so older configs keep working.
"""
from __future__ import annotations

import pytest

import durations


@pytest.mark.parametrize(
    "value, expected",
    [
        ("30s", 30),
        ("5m", 300),
        ("2h", 7200),
        ("1h", 3600),
        (0, 0),
        (60, 60),
        ("60", 60),
        ("0s", 0),
    ],
)
def test_parse_valid(value, expected):
    assert durations.parse_duration(value) == expected


@pytest.mark.parametrize(
    "value",
    [
        None,
        "",
        "   ",
        "abc",
        "10x",          # unknown suffix
        "1.5h",         # we don't accept fractional durations
        -5,             # negatives are nonsensical for a timeout
        True,           # bool subclasses int but we want a real number
        "5 m",          # whitespace inside the string
    ],
)
def test_parse_invalid_raises(value):
    with pytest.raises(ValueError):
        durations.parse_duration(value)


@pytest.mark.parametrize(
    "seconds, expected",
    [
        (0, "0s"),
        (30, "30s"),
        (60, "1m"),
        (90, "90s"),
        (300, "5m"),
        (3600, "1h"),
        (7200, "2h"),
        (3601, "3601s"),    # not a clean hour - drop to seconds
    ],
)
def test_format_roundtrip_compactness(seconds, expected):
    assert durations.format_duration(seconds) == expected


def test_format_negative_falls_through():
    # Negative input is not a normal use case, but the function must not
    # raise. Returning a literal "-Ns" is fine.
    assert durations.format_duration(-1) == "-1s"
