"""Unit tests for the fingerprint logic.

These pin three behaviours we already burned cycles diagnosing:

  1. The script body and `fingerprint_inputs` are part of the digest.
  2. The full task environment is NOT part of the digest. (A previous
     version hashed every env var and re-ran the entire pipeline whenever
     any unrelated var changed.)
  3. Presigned-S3 URLs are stabilised through the object's ETag exactly
     once. (The earlier bug double-applied the regex and produced
     `s3://bucket/key#etag=X#etag=X`.)
"""
from __future__ import annotations

import hashlib
from typing import Optional

import pytest

import fingerprint


class _StubResolver:
    """Drop-in for fingerprint.S3EtagResolver in unit tests."""

    def __init__(self, mapping: dict[tuple[str, str], str]) -> None:
        self._map = mapping
        self.calls: list[tuple[str, str]] = []

    def lookup(self, bucket: str, key: str) -> str:
        self.calls.append((bucket, key))
        return self._map.get((bucket, key), "")


def test_script_change_changes_digest():
    parts_a = fingerprint.compute(
        script_body=b"echo hello",
        env={},
        extra_inputs=[],
    )
    parts_b = fingerprint.compute(
        script_body=b"echo world",
        env={},
        extra_inputs=[],
    )
    assert parts_a.combined() != parts_b.combined()


def test_env_change_does_not_change_digest():
    """Regression guard for the over-eager cache invalidation bug.

    Hashing the entire env meant that bumping API_TARBALL_URL invalidated
    every task in the pipeline, not just the one that actually downloads
    the tarball. The fix scoped invalidation to fingerprint_inputs.
    """
    parts_a = fingerprint.compute(
        script_body=b"#!/usr/bin/env bash\necho ok",
        env={"X": "1"},
        extra_inputs=[],
    )
    parts_b = fingerprint.compute(
        script_body=b"#!/usr/bin/env bash\necho ok",
        env={"X": "2"},
        extra_inputs=[],
    )
    assert parts_a.combined() == parts_b.combined()


def test_fingerprint_inputs_do_change_digest():
    parts_a = fingerprint.compute(
        script_body=b"#!/usr/bin/env bash",
        env={"NAME": "alice"},
        extra_inputs=["{{NAME}}"],
    )
    parts_b = fingerprint.compute(
        script_body=b"#!/usr/bin/env bash",
        env={"NAME": "bob"},
        extra_inputs=["{{NAME}}"],
    )
    assert parts_a.combined() != parts_b.combined()


def test_https_s3_url_resolves_to_etag_form():
    resolver = _StubResolver({("bkt", "k.tar.gz"): "deadbeef"})
    parts = fingerprint.compute(
        script_body=b"",
        env={"URL": "https://bkt.s3.us-east-2.amazonaws.com/k.tar.gz?X-Amz=stuff"},
        extra_inputs=["{{URL}}"],
        etag_resolver=resolver,
    )
    assert parts.inputs_resolved == ["s3://bkt/k.tar.gz#etag=deadbeef"]


def test_no_double_etag_when_input_is_already_s3_form():
    """The regex pass for s3:// URLs must not re-fire on output that the
    https:// pass produced. A bare s3:// URL also gets stabilised, but
    pre-stabilised text passes through untouched."""
    resolver = _StubResolver({("bkt", "k.tar.gz"): "deadbeef"})
    parts = fingerprint.compute(
        script_body=b"",
        env={"URL": "https://bkt.s3.us-east-2.amazonaws.com/k.tar.gz"},
        extra_inputs=["{{URL}}"],
        etag_resolver=resolver,
    )
    # Single etag, not two
    assert parts.inputs_resolved == ["s3://bkt/k.tar.gz#etag=deadbeef"]
    assert parts.inputs_resolved[0].count("#etag=") == 1


def test_bare_s3_scheme_stabilised_independently():
    resolver = _StubResolver({("bkt", "obj/v1"): "abc123"})
    parts = fingerprint.compute(
        script_body=b"",
        env={"URI": "s3://bkt/obj/v1"},
        extra_inputs=["{{URI}}"],
        etag_resolver=resolver,
    )
    assert parts.inputs_resolved == ["s3://bkt/obj/v1#etag=abc123"]


def test_s3_url_falls_back_to_url_only_when_etag_lookup_fails():
    resolver = _StubResolver({})  # nothing matches; lookup returns ""
    parts = fingerprint.compute(
        script_body=b"",
        env={"URL": "https://bkt.s3.us-east-2.amazonaws.com/k.tar.gz"},
        extra_inputs=["{{URL}}"],
        etag_resolver=resolver,
    )
    assert parts.inputs_resolved == ["s3://bkt/k.tar.gz"]


def test_diff_returns_lines_for_each_changed_part():
    prev = {
        "script_digest": hashlib.sha256(b"old").hexdigest(),
        "inputs_digest": hashlib.sha256(b"old-inputs").hexdigest(),
        "inputs_resolved": ["x", "y"],
    }
    current = fingerprint.compute(
        script_body=b"new",
        env={},
        extra_inputs=["alpha", "beta"],
    )
    lines = fingerprint.diff(prev, current)
    joined = "\n".join(lines)
    assert "script body:" in joined
    assert "fp_inputs:" in joined


def test_diff_no_lines_when_unchanged():
    parts = fingerprint.compute(
        script_body=b"same",
        env={},
        extra_inputs=["a"],
    )
    prev = {
        "script_digest": parts.script_digest,
        "inputs_digest": parts.inputs_digest,
        "inputs_resolved": list(parts.inputs_resolved),
    }
    assert fingerprint.diff(prev, parts) == []
