# Next experiment: per-step logit diff (not yet executed)

This procedure is described but **not yet run** in this investigation. It is
the single next step recommended in `../README.md` ("Next experiment"), and
it is designed to be nearly free: one prompt, greedy decoding, and a handful
of small completions requests against an already-served endpoint. No new
compile is needed if you already have a single-shot or segmented build up
from `../README.md`'s "How to run" section.

## Why this experiment, and why now

Every isolation script in this package (`version_isolation_trace.py`,
`plugin_flags_trace.py`, `chunked_ssd_component.py`,
`moe_router_component.py`) runs a **single forward pass**. None of them
exercises the decode path — the loop that carries the Mamba2 recurrent state
from one generated token to the next. Since this model has no positional
encoding and carries all positional information exclusively in that state,
a bug in how the plugin's runtime hands that state from prefill to the first
decode step, or from one decode step to the next, would selectively break
exactly the failure pattern observed (multi-step and order-dependent
reasoning fails; short completions and attention-mediated recall, a separate
code path, survive) while being completely invisible to every single-forward
experiment in this package. See "Ranked candidates" in `../README.md`.

This experiment answers one question cheaply: **does the divergence from the
CPU reference start at the first generated token, or only later?**

- First token already wrong => the defect is observable at prefill/first-logit
  time. This favors the prefill/compile-time candidates (static-graph
  capture baking in prefill-specific semantics, a shared compiler pass, MoE
  dispatch/combine, or weight staging) over a pure decode-step defect.
- First token correct, divergence appears at generated position 2 or later
  => this favors the decode-path / SSM-state-handoff family of candidates
  specifically.

One data point already in this package leans toward the first case: on the
failing arithmetic probes, the plugin's first generated token is already
wrong (it generates `" twice"` where the CPU reference generates `" 6"` for
the `arith_bob` prompt). That is a single prompt's top-1 token, not a
step-by-step logit comparison across multiple prompts, so it should be
treated as a lead to confirm with the procedure below, not as a settled
result.

## Method A: incremental teacher-forced single-token requests

This method needs nothing beyond the OpenAI-compatible completions endpoint
already used by `probes.py` and works regardless of whether your build
supports the `logprobs` request field. It finds the first step where the
device's own greedy choice disagrees with the CPU reference's greedy choice,
by forcing the device to continue from the CPU reference's tokens at every
step and checking only the next token it would generate.

First, obtain the CPU reference's greedy continuation for your chosen
failing prompt (the same Hugging Face pure-PyTorch fallback path used
elsewhere in this investigation, `trust_remote_code=False`, greedy decoding,
temperature 0). Record it as a list of token strings or IDs,
`cpu_tokens = [cpu_tokens[0], cpu_tokens[1], ...]`.

Then, for each prefix length `i` from 0 up to the length of `cpu_tokens`,
send the prompt concatenated with `cpu_tokens[:i]` to the device endpoint
with `max_tokens=1` and `temperature=0`, and compare the single token it
returns against `cpu_tokens[i]`:

```python
import json
import urllib.request

BASE = "http://localhost:8000/v1/completions"
MODEL = "nemotron-h"
PROMPT = "Bob has 3 apples. Alice has twice as many apples as Bob. Alice has"
CPU_TOKENS = [" 6", " apples", "."]


def next_token(text):
    body = json.dumps(
        {"model": MODEL, "prompt": text, "max_tokens": 1, "temperature": 0}
    ).encode()
    req = urllib.request.Request(BASE, body, {"Content-Type": "application/json"})
    d = json.load(urllib.request.urlopen(req, timeout=60))
    return d["choices"][0]["text"]


first_divergent_step = None
for i in range(len(CPU_TOKENS)):
    prefix = PROMPT + "".join(CPU_TOKENS[:i])
    device_next = next_token(prefix)
    matches = device_next.strip() == CPU_TOKENS[i].strip()
    print(i, repr(device_next), repr(CPU_TOKENS[i]), matches)
    if not matches and first_divergent_step is None:
        first_divergent_step = i

print("first_divergent_step:", first_divergent_step)
```

`first_divergent_step == 0` means the very first generated token already
disagrees (prefill/first-logit divergence). Any larger value localizes the
divergence to a specific decode step, which is informative on its own — for
example, disagreement starting at step 3 out of 6 rules out a handoff bug
that would corrupt state from the very first decode step onward, and
narrows the search to whatever changes at that particular step.

This method gives you top-1 token agreement per step, which is enough to
find the first divergent step. It does not give you the full logit vector or
a magnitude, so it cannot by itself distinguish "the device's second-best
choice is a near-tie with a tiny numerical nudge" from "the device's
top choice is a completely different token." If your build's completions
endpoint accepts a `logprobs` field and returns the top-k logprobs for the
generated position, request a small `logprobs` value (for example 5) on the
same single-token completions above to get that magnitude information for
free; if it does not (some plugin model ports only implement the pure
generation path and error on `logprobs`), Method A's top-1 comparison above
is still sufficient to answer the first-divergent-step question.

## Method B: on-device self-consistency (no CPU reference needed)

This check isolates the decode graph specifically, holding the device
constant, so it needs no CPU reference at all. Compare:

1. A single call that generates all `N` tokens of the failing continuation
   in one request (`max_tokens=N`) — this is what a normal serving request
   does, exercising prefill followed by `N` on-device decode steps.
2. The same `N` tokens produced by Method A's incremental teacher-forced
   loop above, but feeding the *device's own* previous output back in at
   each step instead of the CPU reference's tokens (i.e. plain greedy
   decoding done one token at a time via repeated single-token completions
   requests instead of one multi-token request).

If (1) and (2) disagree, the disagreement is entirely in how the plugin's
serving path manages state across steps within a single request versus
across separate requests — evidence specifically about the decode graph and
state handoff, independent of any CPU/device discrepancy. If they agree, the
device is at least internally consistent, and the divergence found in
Method A is a property of the model/compile as a whole rather than of
this specific state-management path.

## Optional: SSM state dump (blocked by a known limitation)

The most direct check — dumping the Mamba2 recurrent state tensor
immediately after prefill and after the first decode step, and diffing it
against the CPU reference's state at the same points — is currently blocked
by the `tensor_capture` integration gap described in `../README.md`'s
"Known limitations" (the model port's serving-path forward function returns
logits only, so the capture mechanism's extra outputs are not threaded
through). If that gap is closed with a small change to the model port's
forward function, this is the most precise follow-up: it distinguishes
"state corrupted at the handoff" from "state is fine, but the decode graph
computes the wrong thing from it."

## How to read the result

| Observation | Points toward |
|---|---|
| First generated token already wrong (`first_divergent_step == 0`) | Prefill/compile-time candidates: static-graph capture baking in prefill-specific semantics, a shared compiler pass, MoE dispatch/combine, or weight staging (see "Ranked candidates" in `../README.md`) |
| Divergence starts at a later decode step | Decode-path / SSM-state-handoff candidates |
| Method B's two device-only sequences disagree with each other | The decode graph / cross-request state handling specifically, independent of any CPU comparison |
| Method B's two sequences agree, but both disagree with the CPU reference at the same step as Method A found | The defect is present consistently regardless of how the request is split, which narrows the search to the shared compile/lowering path rather than a request-boundary state bug |

Run this before attempting to isolate any single ranked candidate further.
It is designed to split the remaining hypothesis space in half at near-zero
cost, using infrastructure this package already assumes (a served
completions endpoint and a CPU reference).
