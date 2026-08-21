#!/usr/bin/env python3
"""Reasoning probe suite for a vLLM OpenAI-compatible completions endpoint.

Each probe fits well under 256 output tokens, so it works even against a
single-shot build compiled at max_model_len=256. The suite is designed to
separate "flat" failures (short factual completion, verbatim recall) from
"reasoning" failures (2-hop arithmetic, transitive comparison, multi-step
recall under distraction). See ../05-debug-tooling-and-methods.md for how
these probes were used to localize a Trainium-specific regression in the
NemotronH accuracy investigation.

Usage:
    PROBE_BASE_URL=http://localhost:8000/v1/completions \
    PROBE_MODEL=nemotron-h \
    python3 probes.py "some-label"

Environment variables:
    PROBE_BASE_URL   completions endpoint (default: http://localhost:8000/v1/completions)
    PROBE_MODEL      value for the "model" field in the request body (default: nemotron-h)
    PROBE_TIMEOUT    per-request timeout in seconds (default: 180)

Pass --dry-run to print the probe table without making any network calls
(useful to sanity-check the script itself, e.g. in dry_run_all.sh).
"""
import json
import os
import sys
import urllib.request

BASE = os.environ.get("PROBE_BASE_URL", "http://localhost:8000/v1/completions")
MODEL = os.environ.get("PROBE_MODEL", "nemotron-h")
TIMEOUT = int(os.environ.get("PROBE_TIMEOUT", "180"))


def gen(prompt, mx=12):
    body = json.dumps(
        {"model": MODEL, "prompt": prompt, "max_tokens": mx, "temperature": 0}
    ).encode()
    req = urllib.request.Request(BASE, body, {"Content-Type": "application/json"})
    d = json.load(urllib.request.urlopen(req, timeout=TIMEOUT))
    return d["usage"]["prompt_tokens"], d["choices"][0]["text"]


# Neutral, non-repetitive preamble builder (geography vocabulary) used to pad
# the prompt to a target token count without introducing content the model
# could latch onto or copy from.
VOCAB = (
    "Geography studies places and environments climate terrain population regions history "
    "culture economy rivers mountains coastlines cities agriculture industry tourism people "
    "trade language religion architecture science education transport weather seasons borders "
    "valleys forests deserts islands harbors bridges railways highways markets festivals"
).split()


def preamble(nw):
    return " ".join(VOCAB[i % len(VOCAB)] for i in range(nw))


PROBES = []

# Capital-of-France sweep with a growing neutral preamble (expect "Paris").
# This isolates whether a distractor prefix of a given length disrupts a
# trivial factual completion — a proxy for whether positional/context
# handling degrades with prompt length.
for nw in [0, 8, 16, 30, 45, 70, 100]:
    p = (preamble(nw) + ". " if nw else "") + "The capital of France is"
    PROBES.append(("capital_%d" % nw, p, "Paris"))

# 2-hop arithmetic: the answer requires combining two stated facts, not just
# recalling one. These were the probes that stayed wrong even after the
# 2.31 -> 2.32 SDK upgrade fixed the positional-preamble and comparison
# probes below (see 02-experiments-and-results.md).
PROBES += [
    (
        "arith_bob",
        "Bob has 3 apples. Alice has twice as many apples as Bob. Alice has",
        "6",
    ),
    (
        "arith_tom",
        "Tom is 4 years older than Ana. Ana is 7 years old. Tom is",
        "11",
    ),
    (
        "arith_pen",
        "A pen costs 5 dollars. A notebook costs 3 dollars more than a pen. A notebook costs",
        "8",
    ),
]

# Transitive comparison (expect "red"): requires chaining two relations
# across the prompt rather than reading a single fact.
PROBES += [
    (
        "cmp_box",
        "The red box is heavier than the blue box. The blue box is heavier than the green box. So the heaviest box is the",
        "red",
    ),
]

# Anti-copy: a full worked exemplar on an unrelated topic, then a different
# final question. Expects the model to answer the LAST question ("4") rather
# than regurgitate the exemplar's answer pattern. A model that just copies
# the shape of the preceding answer fails this even though the arithmetic
# itself (2 + 2) is trivial.
PROBES += [
    (
        "anticopy",
        "Question: A bear needs to gain 1000 pounds. It gained 200 pounds from berries. "
        "How many more pounds does it need?\nAnswer: It needs 1000 - 200 = 800 more pounds.\n\n"
        "Question: What is 2 + 2?\nAnswer: 2 + 2 =",
        "4",
    ),
]


def main():
    args = [a for a in sys.argv[1:] if a != "--dry-run"]
    dry_run = "--dry-run" in sys.argv[1:]
    label = args[0] if args else "run"

    if dry_run:
        print("== probe suite [dry-run] base=%s model=%s ==" % (BASE, MODEL))
        for name, prompt, expect in PROBES:
            print("%-14s expect=%-6s prompt=%r" % (name, expect, prompt[:60]))
        print("[dry-run] OK: %d probes defined, no network calls made" % len(PROBES))
        return

    npass = 0
    print("== probe suite [%s] base=%s model=%s ==" % (label, BASE, MODEL))
    for name, prompt, expect in PROBES:
        try:
            pt, g = gen(prompt)
        except Exception as e:
            print("%-14s ERR %s" % (name, e))
            continue
        ok = expect.lower() in g.lower()
        npass += ok
        print(
            "%-14s ptok=%3d [%s] expect=%-6s gen=%r"
            % (name, pt, "PASS" if ok else "FAIL", expect, g[:60])
        )
    print("== %s: %d/%d pass ==" % (label, npass, len(PROBES)))


if __name__ == "__main__":
    main()
