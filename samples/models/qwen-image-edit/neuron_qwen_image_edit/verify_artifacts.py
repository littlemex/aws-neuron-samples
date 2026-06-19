#!/usr/bin/env python3
"""
verify_artifacts.py — consistency gate for compiled Qwen-Image-Edit artifacts.

Run this BEFORE serving (and as the skip-if-cached predicate at deploy time) so
that an inconsistent or half-written artifact set is rejected with a clear
message instead of crash-looping deep inside ``NxDModel.to_neuron()`` with the
opaque ``RuntimeError: Expected weight tensors for N ranks. Received M``.

Background (post-incident 2026-06)
----------------------------------
The transformer artifact dir for the V3 CFG layout contains:

    transformer_v3_cfg/
        nxd_model.pt      # the SPMD graph (rank count baked in at trace time)
        config.json       # {tp_degree, world_size, dp_degree, ...}
        weights/tp0..tp{tp_degree-1}_sharded_checkpoint.safetensors
        rope_cache.pt
        .compile_stamp    # written LAST by compile_transformer_v3_cfg.py

Three independent files encode the parallel layout (the graph, the config, and
the shard count). They can drift apart in real failure modes:

  * a stale Neuron compile-cache hit returns a graph for a *different*
    world_size than the one config/weights were just regenerated for;
  * a compile killed midway leaves a graph from one run next to weights/config
    from another.

We cannot read the rank count back out of ``nxd_model.pt`` on a plain CPU box
(its ``__torch__.torch.classes.neuron.SPMDModel`` type is unregistered off the
Neuron runtime, so ``torch.jit.load`` raises). So the authoritative record is
``.compile_stamp``, written in the *same process* that traced+compiled the
graph, only after every other file landed. This gate asserts:

  1. ``.compile_stamp`` exists  -> the dir is a COMPLETE compile, not a
     half-written / interrupted one.
  2. ``stamp.world_size == config.world_size`` and
     ``stamp.tp_degree == config.tp_degree`` -> the graph and the config agree
     on the layout (catches a stale-cache graph paired with a fresh config).
  3. the number of ``tp*_sharded_checkpoint.safetensors`` files equals
     ``tp_degree`` -> the weights match the layout the loader will expand to
     ``world_size`` via DP duplication.

A deliberately AVOIDED check: comparing ``nxd_model.pt`` mtime against the
weights. The compiler writes the graph BEFORE the weights, so the graph is
always "older" in a perfectly good compile; an mtime check produces false
"stale NEFF" rejections. The stamp is the correct, order-independent signal.

CLI
---
    python -m neuron_qwen_image_edit.verify_artifacts <dir> [<dir> ...]
exit code 0 = all consistent, 1 = at least one failed (reason on stderr).
"""

import json
import os
import sys


STAMP_FILE = ".compile_stamp"


class ArtifactInconsistencyError(RuntimeError):
    """Raised when a compiled artifact dir is incomplete or self-inconsistent."""


def _count_weight_shards(component_dir):
    weights_dir = os.path.join(component_dir, "weights")
    if not os.path.isdir(weights_dir):
        return 0
    return sum(
        1
        for name in os.listdir(weights_dir)
        if name.startswith("tp")
        and name.endswith("_sharded_checkpoint.safetensors")
    )


def verify_component(component_dir, require_stamp=True):
    """Verify one compiled component dir. Raises ArtifactInconsistencyError on any
    inconsistency; returns the parsed stamp dict on success."""
    name = os.path.basename(component_dir.rstrip("/"))

    config_path = os.path.join(component_dir, "config.json")
    nxd_path = os.path.join(component_dir, "nxd_model.pt")
    stamp_path = os.path.join(component_dir, STAMP_FILE)

    if not os.path.isfile(nxd_path):
        raise ArtifactInconsistencyError(f"{name}: nxd_model.pt missing")
    if not os.path.isfile(config_path):
        raise ArtifactInconsistencyError(f"{name}: config.json missing")

    if not os.path.isfile(stamp_path):
        if require_stamp:
            raise ArtifactInconsistencyError(
                f"{name}: {STAMP_FILE} missing -> compile was never finished "
                f"(interrupted or pre-dates the completion-stamp change). Recompile required."
            )
        return None

    with open(config_path) as f:
        config = json.load(f)
    with open(stamp_path) as f:
        stamp = json.load(f)

    cfg_ws = config.get("world_size")
    cfg_tp = config.get("tp_degree")
    st_ws = stamp.get("world_size")
    st_tp = stamp.get("tp_degree")

    if st_ws != cfg_ws:
        raise ArtifactInconsistencyError(
            f"{name}: stamp world_size={st_ws} != config world_size={cfg_ws} "
            f"-> stale graph paired with a mismatched config. Recompile required."
        )
    if st_tp != cfg_tp:
        raise ArtifactInconsistencyError(
            f"{name}: stamp tp_degree={st_tp} != config tp_degree={cfg_tp}. Recompile required."
        )

    expected_shards = stamp.get("shard_count", cfg_tp)
    actual_shards = _count_weight_shards(component_dir)
    if actual_shards != expected_shards:
        raise ArtifactInconsistencyError(
            f"{name}: found {actual_shards} weight shards, expected {expected_shards} "
            f"(tp_degree={cfg_tp}). Recompile required."
        )

    print(
        f"[OK] {name}: world_size={cfg_ws}, tp_degree={cfg_tp}, shards={actual_shards}",
        flush=True,
    )
    return stamp


def verify_all(dirs, require_stamp=True):
    """Verify several component dirs. Returns True if all pass, else False
    (printing the reason to stderr). Never raises."""
    ok = True
    for d in dirs:
        try:
            verify_component(d, require_stamp=require_stamp)
        except (ArtifactInconsistencyError, OSError, ValueError) as exc:
            print(f"[NG] {exc}", file=sys.stderr, flush=True)
            ok = False
    return ok


if __name__ == "__main__":
    targets = sys.argv[1:]
    if not targets:
        print(
            "usage: python -m neuron_qwen_image_edit.verify_artifacts <component_dir> ...",
            file=sys.stderr,
        )
        sys.exit(2)
    sys.exit(0 if verify_all(targets, require_stamp=True) else 1)
