#!/usr/bin/env python3
"""rewrite-explorer-bundle.py

Build-time SPA bundle rewriter for Neuron Explorer.

The Explorer SPA bundle ships URL-construction logic that branches on
whether `window.NEURON_API_URL` contains "localhost".  When the SPA is
served from a non-localhost origin (e.g. behind nginx + CloudFront),
the production branch builds absolute URLs against a bare hostname
("explorer") with a "/prod/api/..." prefix — neither of which resolves
on a same-origin deployment.

This script transforms the upstream bundle ONCE at deploy time, then
nginx serves the transformed copy from disk.  No request-time rewrite
is performed, so there is no per-request CPU cost or sub_filter
buffering surprise.

Algorithm
=========
1. Fetch the upstream bundle from the running Explorer view server
   (default http://127.0.0.1:8081).  We discover the asset filename
   by parsing the index HTML's <script type="module"> tag, so we do
   NOT hard-code the bundle's content-hashed filename.
2. Compute sha256 of the upstream bytes.  If it matches the saved
   marker, exit 0 (idempotent, nothing to do).
3. Apply the regex substitution table below.  Each pattern has a
   minimum-hits expectation; if any required pattern matches zero
   times, mark the result DEGRADED but still emit a usable file
   (fail-open: write the unmodified bundle so the SPA at least
   loads, even if profile detail does not).
4. Atomically write the transformed bundle to the output dir, then
   write the sha256 marker, then write the human-readable status.
5. The status file is exposed by nginx at /explorer/health so an
   operator (or a smoke test) can confirm the rewriter ran cleanly.

Usage
=====
    rewrite-explorer-bundle.py                # all defaults
    rewrite-explorer-bundle.py --dry-run      # report hits, do not write
    rewrite-explorer-bundle.py --upstream URL --out DIR --status FILE

The defaults are tuned for the systemd unit; CLI flags exist for
manual debugging.
"""

from __future__ import annotations

import argparse
import hashlib
import logging
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_UPSTREAM = "http://127.0.0.1:8081"
DEFAULT_OUT_DIR = "/var/lib/neuron-explorer/assets"
DEFAULT_STATUS = "/var/lib/neuron-explorer/rewriter.status"
DEFAULT_SHA_MARK = "/var/lib/neuron-explorer/bundle.sha256"
DEFAULT_PREFIX = "/explorer"  # nginx sub-path the SPA is served from

# Regex substitution table.  Order matters; see comments inline.
# Each tuple is (label, pattern, replacement, expected_min_hits).
#
# All replacements assume the SPA is mounted at /explorer/.  The
# bundle's URL builders end up emitting paths that begin with
# /explorer/api/v1/...  which nginx (and ALB / CloudFront upstream)
# already routes to the Explorer backend.
SUBSTITUTIONS: list[tuple[str, str, str, int]] = [
    # 1. The SPA selects between localhost-mode and prod-mode using
    #    `endpoint.includes("localhost")`.  We force every check to
    #    "always-true" by replacing the literal with an empty string,
    #    so the prod-mode branch never fires and the URL builders
    #    use the cleaner `/api/v1/...` paths instead of `/prod/api/v1/...`.
    (
        "includes-localhost",
        r'\.includes\(\s*"localhost"\s*\)',
        '.includes("")',
        1,
    ),
    # 2. Production-mode prefix `/prod/api/v1/` becomes the SPA mount
    #    point + same path.  Even though substitution #1 routes most
    #    callers to the localhost branch, a couple of getter methods
    #    interpolate this string directly via template literals;
    #    rewriting it here keeps the bundle internally consistent.
    (
        "prod-api-v1-prefix",
        r"/prod/api/v1/",
        "/explorer/api/v1/",
        1,
    ),
    # 3. Versioned variant `/prod/api/${t}/...` (used in
    #    `_profileDbPath` where the version is a parameter).
    (
        "prod-api-versioned-template",
        r"/prod/api/\$\{t\}",
        "/explorer/api/${t}",
        1,
    ),
    # 4. Trailing-slash-less form `/prod/api/v1` (ternary literal in
    #    `getTransferBandwidth`).  Optional: usually covered by #2,
    #    but the JS minifier sometimes emits both forms.
    (
        "prod-api-v1-noslash",
        r"/prod/api/v1\b",
        "/explorer/api/v1",
        0,
    ),
    # 5. Concat URL builder `r + "//" + this.endpoint + <var>`.  The
    #    SPA assembles an absolute URL like "https://explorer/api/...",
    #    which is wrong on a sub-path deployment.  We replace the
    #    scheme/host part with the SPA mount path so fetch() resolves
    #    a same-origin URL like "/explorer/api/v1/...".
    (
        "concat-url-build",
        r'r\s*\+\s*"//"\s*\+\s*this\.endpoint\s*\+\s*([a-z])',
        r'"/explorer" + \1',
        1,
    ),
    # 6. Same shape but with a different proto-variable name — minified
    #    code reuses single letters, so allow any.
    (
        "concat-url-build-proto-alt",
        r'(?<![a-zA-Z_$])([a-z])\s*\+\s*"//"\s*\+\s*this\.endpoint\s*\+\s*([a-z])',
        r'"/explorer" + \2',
        1,
    ),
    # 7. Template-literal builder `${proto}//${this.endpoint}${path}`.
    #    Same problem as #5/#6, different syntactic form.
    (
        "template-url-build",
        r"`\$\{[^`{}]+?\}//\$\{this\.endpoint\}\$\{([a-z])\}`",
        r"`/explorer${\1}`",
        1,
    ),
]

# Patterns that MUST NOT remain in the transformed bundle.  After
# applying every substitution above, all of these should match zero
# times.  If any survives, the rewrite is incomplete and we mark the
# output DEGRADED.
RESIDUE_CHECKS: list[tuple[str, str]] = [
    ("/prod/api leftovers", r"/prod/api"),
    (
        "scheme + this.endpoint leftovers",
        r"//\$?\{?this\.endpoint\}?",
    ),
    (
        '.includes("localhost") leftovers',
        r'\.includes\(\s*"localhost"\s*\)',
    ),
]


def fetch_url(url: str, *, timeout: int = 30) -> bytes:
    req = urllib.request.Request(url, headers={"User-Agent": "explorer-rewriter/1"})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return resp.read()


def discover_bundle_paths(upstream: str) -> list[str]:
    """Parse the SPA shell HTML to find every JS asset the page loads.

    The shell looks roughly like:
        <script type="module" src="/assets/index.<hash>.js">
        <link rel="modulepreload" href="/assets/cloudscape.<hash>.js">
        <link rel="modulepreload" href="/assets/profiler.<hash>.js">
        <link rel="modulepreload" href="/assets/vendor.<hash>.js">

    The URL-construction logic lives only in profiler.*.js as of
    Neuron Explorer 2.30, but the cloudscape/vendor chunks share the
    same content-hash convention and may absorb the API code in a
    future SDK version.  We rewrite all of them defensively; bundles
    with zero URL-build patterns are still copied so that nginx serves
    a complete asset set from disk and try_files never has to fall
    back for chunks the rewriter "should" have written.
    """
    shell = fetch_url(f"{upstream}/").decode("utf-8")
    paths = re.findall(
        r'(?:src|href)="(/assets/[^"]+\.js)"',
        shell,
    )
    if not paths:
        raise RuntimeError(
            f"could not find any /assets/*.js references in {upstream}/"
        )
    # de-dup while preserving order
    seen: set[str] = set()
    out: list[str] = []
    for p in paths:
        if p not in seen:
            seen.add(p)
            out.append(p)
    return out


def _apply_prefix(replacement: str, prefix: str) -> str:
    """Inject the runtime sub-path prefix into a substitution template.

    The substitution table is written with `/explorer` as a literal
    placeholder for readability; here we swap it out for whatever
    sub-path the operator chose (e.g. `/explorer`, `/profiler`, ...).
    Empty prefix collapses to a same-origin root.
    """
    return replacement.replace("/explorer", prefix)


def transform(src: str, prefix: str = DEFAULT_PREFIX) -> tuple[str, dict[str, int], dict[str, int]]:
    """Apply every substitution to a single bundle.

    Args:
        src     : raw bundle source (utf-8 decoded).
        prefix  : nginx sub-path the SPA is mounted at, e.g. "/explorer".
                  Substitutions inject this so fetch() lands on the
                  same nginx site that serves the UI.

    Returns:
        (transformed_text, hits, residue) where
            hits     = {label: count}  per-rule occurrences
            residue  = {label: count}  per post-rewrite check

    No min-hit assertion happens here — the caller decides whether
    zero hits in a particular bundle is acceptable, because URL-build
    code lives in only one chunk (profiler.*.js); other chunks
    (vendor / cloudscape) hit zero by design.
    """
    out = src
    hits: dict[str, int] = {}
    for label, pat, repl, _lo in SUBSTITUTIONS:
        regex = re.compile(pat)
        n = len(regex.findall(out))
        hits[label] = n
        out = regex.sub(_apply_prefix(repl, prefix), out)

    residue: dict[str, int] = {}
    for label, pat in RESIDUE_CHECKS:
        residue[label] = len(re.findall(pat, out))

    return out, hits, residue


def atomic_write(path: Path, data: bytes, mode: int = 0o644) -> None:
    """Write `data` to `path` atomically by writing to a sibling tmp file
    then renaming.  Forces world-readable permissions so nginx (running
    as www-data, NOT the bundle's owning user) can serve the file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".tmp-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "wb") as f:
            f.write(data)
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass
        raise


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument(
        "--upstream",
        default=DEFAULT_UPSTREAM,
        help="Explorer view server base URL (default: %(default)s)",
    )
    p.add_argument(
        "--out",
        default=DEFAULT_OUT_DIR,
        help="output directory for rewritten assets (default: %(default)s)",
    )
    p.add_argument(
        "--status",
        default=DEFAULT_STATUS,
        help="status file written by the rewriter (default: %(default)s)",
    )
    p.add_argument(
        "--mark",
        default=DEFAULT_SHA_MARK,
        help="sha256 marker file used for idempotency (default: %(default)s)",
    )
    p.add_argument(
        "--prefix",
        default=DEFAULT_PREFIX,
        help="nginx sub-path the SPA is served from (default: %(default)s)",
    )
    p.add_argument(
        "--dry-run",
        action="store_true",
        help="report what would happen, write nothing",
    )
    p.add_argument(
        "--force",
        action="store_true",
        help="run even if the sha256 marker says we already rewrote this bundle",
    )
    p.add_argument("-v", "--verbose", action="count", default=0)
    args = p.parse_args()

    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
    )
    log = logging.getLogger("rewriter")

    out_dir = Path(args.out)
    status_file = Path(args.status)
    mark_file = Path(args.mark)

    # ------------------------------------------------------------------
    # Step 1: Discover every JS asset the SPA shell loads.
    # ------------------------------------------------------------------
    try:
        bundle_paths = discover_bundle_paths(args.upstream)
    except (urllib.error.URLError, RuntimeError) as exc:
        log.error("could not discover upstream bundles: %s", exc)
        # If the upstream is not reachable, do nothing.  nginx will
        # fall back via try_files @upstream-explorer-assets.
        return 0
    log.info("upstream bundles: %s", ", ".join(bundle_paths))

    # ------------------------------------------------------------------
    # Step 2: Fetch all bundle bytes, compute aggregate sha256 over
    #         their concatenation (in shell-listed order).  This is
    #         the idempotency key.
    # ------------------------------------------------------------------
    raw_bundles: dict[str, bytes] = {}
    digest = hashlib.sha256()
    for p in bundle_paths:
        url = args.upstream.rstrip("/") + p
        data = fetch_url(url)
        raw_bundles[p] = data
        digest.update(data)
        log.info("    %s: %d bytes", p, len(data))
    aggregate_sha = digest.hexdigest()
    log.info("aggregate sha256: %s", aggregate_sha)

    if not args.force and mark_file.exists():
        prev = mark_file.read_text().strip()
        if prev == aggregate_sha:
            log.info("bundles unchanged (aggregate sha matches marker); nothing to do")
            return 0
        log.info("bundles changed; previous sha256 was %s", prev)

    # ------------------------------------------------------------------
    # Step 3: Transform each bundle.  Aggregate residue across all
    #         chunks; we DO NOT require every chunk to hit every
    #         pattern, because URL-build code may live in just one
    #         chunk (profiler.*.js).  A bundle is OK if its hit table
    #         + residue table are all >= 0 with no leftover patterns
    #         AFTER the rewrite.
    # ------------------------------------------------------------------
    per_bundle: list[tuple[str, dict[str, int], dict[str, int], bytes]] = []
    aggregate_residue: dict[str, int] = {label: 0 for label, _ in RESIDUE_CHECKS}
    aggregate_hits: dict[str, int] = {label: 0 for label, _, _, _ in SUBSTITUTIONS}

    for p in bundle_paths:
        data = raw_bundles[p]
        text = data.decode("utf-8")
        transformed, hits, residue = transform(text, prefix=args.prefix)
        per_bundle.append((p, hits, residue, transformed.encode("utf-8")))
        for k, v in hits.items():
            aggregate_hits[k] += v
        for k, v in residue.items():
            aggregate_residue[k] += v
        log.info(
            "    %s: hits=%s residue=%s",
            p,
            {k: v for k, v in hits.items() if v},
            {k: v for k, v in residue.items() if v},
        )

    # The "minimum hit" check applies to the AGGREGATE across all
    # chunks.  If after rewriting every URL-build pattern is gone
    # (residue all zero) AND every required substitution fired at
    # least once globally, we declare OK.  Otherwise DEGRADED.
    warnings: list[str] = []
    for label, _pat, _repl, lo in SUBSTITUTIONS:
        if aggregate_hits[label] < lo:
            warnings.append(
                f"required substitution {label!r} matched {aggregate_hits[label]} time(s) "
                f"across all chunks (expected >= {lo})"
            )
    for label, n in aggregate_residue.items():
        if n > 0:
            warnings.append(f"residue {label!r} found {n} time(s) across all chunks")

    state = "OK" if not warnings else "DEGRADED"
    log.info("substitution totals: %s", aggregate_hits)
    log.info("residue totals     : %s", aggregate_residue)
    if warnings:
        for w in warnings:
            log.warning(w)
    else:
        log.info("all substitutions and residue checks passed across all chunks")

    if args.dry_run:
        log.info("dry-run: not writing any files")
        return 0 if state == "OK" else 1

    # ------------------------------------------------------------------
    # Step 4: write every chunk to the output dir.
    #         OK    -> rewritten bytes
    #         DEGRADED -> original bytes (fail-open)
    # ------------------------------------------------------------------
    out_dir.mkdir(parents=True, exist_ok=True)
    for p, _hits, _res, transformed_bytes in per_bundle:
        payload = transformed_bytes if state == "OK" else raw_bundles[p]
        target = out_dir / Path(p).name
        atomic_write(target, payload)
        log.info("wrote %s (%d bytes)", target, target.stat().st_size)

    mark_file.parent.mkdir(parents=True, exist_ok=True)
    mark_file.write_text(aggregate_sha + "\n")

    status_lines = [
        f"{state} sha256={aggregate_sha} chunks={len(bundle_paths)}",
        f"timestamp={int(time.time())}",
        f"upstream={args.upstream}",
        f"output={out_dir}",
    ]
    for p in bundle_paths:
        status_lines.append(f"chunk={Path(p).name}")
    for label, n in aggregate_hits.items():
        status_lines.append(f"hit:{label}={n}")
    for label, n in aggregate_residue.items():
        status_lines.append(f"residue:{label}={n}")
    for w in warnings:
        status_lines.append(f"warning:{w}")
    status_file.parent.mkdir(parents=True, exist_ok=True)
    status_file.write_text("\n".join(status_lines) + "\n")
    log.info("wrote status to %s", status_file)

    return 0 if state == "OK" else 2


if __name__ == "__main__":
    sys.exit(main())
