"""Content-addressed fingerprints for cache invalidation.

A task is skipped on re-run when its fingerprint matches the recorded one.
The fingerprint is sha256 over, in order:

  1. The script body (as bytes).
  2. Each ``fingerprint_inputs`` entry, after ``{{NAME}}`` expansion. Entries
     that look like S3 URLs (presigned HTTPS or ``s3://``) are replaced by
     the object's ETag through one ``head-object`` call (cached for the run).

What is intentionally NOT in the digest: the full task environment. Pipelines
inject many env vars (region, model id, tarball URL, ...) but most tasks use
only a few. Hashing the whole env would invalidate every task whenever any
unrelated var moved, which we observed in the field. Each task is now
responsible for declaring the vars whose change should invalidate its cache,
through ``fingerprint_inputs:`` -- the YAML reads more verbosely but the
cache behaves the way an operator would expect.

The S3 ETag lookup is failure-tolerant: when it fails we fall back to the
URL key only, exactly like the old runner did.
"""
from __future__ import annotations

import hashlib
import re
import subprocess
from dataclasses import dataclass
from typing import Mapping, Optional


_HTTPS_S3_RE = re.compile(
    r"https?://([a-z0-9.\-]+)\.s3[.\-][a-z0-9\-]+\.amazonaws\.com(/[^\s\"']*)"
)
_S3_SCHEME_RE = re.compile(r"s3://([a-z0-9.\-]+)/([^\s\"'?#]+)")


@dataclass
class FingerprintParts:
    """Per-input pieces, kept around so we can render diffs."""

    script_digest: str
    inputs_digest: str
    inputs_resolved: list[str]

    def combined(self) -> str:
        h = hashlib.sha256()
        h.update(self.script_digest.encode())
        h.update(b"\n")
        h.update(self.inputs_digest.encode())
        return h.hexdigest()


class S3EtagResolver:
    """Looks up S3 ``ETag`` values, with a per-instance cache.

    Instantiated once per pipeline run. Failures (network blip, IAM denial,
    missing aws CLI) yield an empty ETag rather than raising; callers fall
    back to the URL-key-only key in that case.
    """

    def __init__(self, *, timeout: float = 20.0):
        self._cache: dict[tuple[str, str], str] = {}
        self._timeout = timeout

    def lookup(self, bucket: str, key: str) -> str:
        cache_key = (bucket, key)
        if cache_key in self._cache:
            return self._cache[cache_key]
        try:
            result = subprocess.run(
                [
                    "aws", "s3api", "head-object",
                    "--bucket", bucket,
                    "--key", key,
                    "--query", "ETag",
                    "--output", "text",
                ],
                capture_output=True,
                text=True,
                timeout=self._timeout,
            )
            if result.returncode == 0:
                etag = (result.stdout or "").strip().strip('"')
            else:
                etag = ""
        except (subprocess.TimeoutExpired, FileNotFoundError):
            etag = ""
        self._cache[cache_key] = etag
        return etag


def _stabilise_url(text: str, etag_resolver: Optional[S3EtagResolver]) -> str:
    """Replace S3 URLs in ``text`` with a stable identifier.

    We try ``https://...`` first (the form deploy.sh hands us via presigned
    URLs) and fall back to ``s3://...`` only if the text was NOT already
    rewritten by the HTTPS pass; the bare ``s3://`` regex would otherwise
    match the output of the HTTPS pass and append the ETag a second time.
    """
    if etag_resolver is None:
        return text

    def _https_sub(match: re.Match[str]) -> str:
        bucket, key = match.group(1), match.group(2)
        if "?" in key:
            key = key.split("?", 1)[0]
        key = key.lstrip("/")
        etag = etag_resolver.lookup(bucket, key)
        return f"s3://{bucket}/{key}#etag={etag}" if etag else f"s3://{bucket}/{key}"

    def _scheme_sub(match: re.Match[str]) -> str:
        bucket, key = match.group(1), match.group(2)
        etag = etag_resolver.lookup(bucket, key)
        return f"s3://{bucket}/{key}#etag={etag}" if etag else f"s3://{bucket}/{key}"

    https_replaced = _HTTPS_S3_RE.sub(_https_sub, text)
    if https_replaced != text:
        # Already normalised through the HTTPS path; do not re-run the
        # bare s3:// pass or we will double-suffix the ETag.
        return https_replaced
    return _S3_SCHEME_RE.sub(_scheme_sub, text)


def expand_placeholders(text: str, env: Mapping[str, str]) -> str:
    """Replace ``{{NAME}}`` placeholders with values from ``env``.

    Used for ``fingerprint_inputs`` entries; the script body itself is never
    template-expanded by the runner.
    """
    out = text
    for name, value in env.items():
        out = out.replace("{{" + name + "}}", value)
    return out


def compute(
    *,
    script_body: bytes,
    env: Mapping[str, str],
    extra_inputs: list[str],
    etag_resolver: Optional[S3EtagResolver] = None,
) -> FingerprintParts:
    """Build a ``FingerprintParts`` for a task invocation.

    ``env`` is used only for placeholder expansion inside ``extra_inputs``.
    It is intentionally NOT hashed itself; see the module docstring.
    """
    script_digest = hashlib.sha256(script_body).hexdigest()

    resolved: list[str] = []
    for raw in extra_inputs:
        expanded = expand_placeholders(raw, env)
        resolved.append(_stabilise_url(expanded, etag_resolver))
    inputs_digest = hashlib.sha256("\n".join(resolved).encode()).hexdigest()

    return FingerprintParts(
        script_digest=script_digest,
        inputs_digest=inputs_digest,
        inputs_resolved=resolved,
    )


def diff(prev: dict, current: FingerprintParts) -> list[str]:
    """Return human-readable lines describing what changed between runs."""
    lines: list[str] = []
    if prev.get("script_digest") != current.script_digest:
        lines.append(
            f"script body: {(prev.get('script_digest') or 'none')[:8]} -> {current.script_digest[:8]}"
        )
    if prev.get("inputs_digest") != current.inputs_digest:
        lines.append(
            f"fp_inputs:   {(prev.get('inputs_digest') or 'none')[:8]} -> {current.inputs_digest[:8]}"
        )
        prev_inputs = prev.get("inputs_resolved") or []
        for i, (a, b) in enumerate(zip(prev_inputs, current.inputs_resolved)):
            if a != b:
                lines.append(f"  input[{i}]: {a} -> {b}")
        if len(prev_inputs) != len(current.inputs_resolved):
            lines.append(
                f"  inputs count: {len(prev_inputs)} -> {len(current.inputs_resolved)}"
            )
    return lines
