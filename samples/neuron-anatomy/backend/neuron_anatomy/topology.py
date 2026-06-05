"""Wrapper around `neuron-ls -j`.

Read once on dashboard startup and cached for the lifetime of the process.
Unlike neuron-monitor, the topology is static so there is no need to keep
a daemon running.

Design notes:
  - No hard-coding of chip count, cores per chip, or adjacency. Everything
    is read from the neuron-ls JSON. trn2.3xlarge (1 chip, no edges),
    trn2.48xlarge (16 chips, 4x4 torus), and Trn2 UltraServer (64 chips)
    are handled by the same code path.
  - When neuron-ls is not available locally (developer laptop, CI), set
    NEURON_ANATOMY_FAKE_TOPOLOGY=1 to enable a synthetic topology so the
    frontend can be exercised without an actual instance. The shape of
    that fake topology can be selected with NEURON_ANATOMY_FAKE_VARIANT
    (default "trn2.48xlarge"; "trn2.3xlarge" yields a single-chip layout).
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
from typing import Optional

from .schemas import (
    ChipEngineSpecs,
    EngineSpec,
    TopologyChip,
    TopologyEdge,
    TopologyResponse,
)

log = logging.getLogger("neuron-anatomy.topology")


_NEURON_LS_BIN = os.environ.get("NEURON_LS_BIN", "/opt/aws/neuron/bin/neuron-ls")
_FAKE = os.environ.get("NEURON_ANATOMY_FAKE_TOPOLOGY", "0") == "1"
_FAKE_VARIANT = os.environ.get("NEURON_ANATOMY_FAKE_VARIANT", "trn2.48xlarge")


# Static specs for a Trainium2 chip, used by the frontend to label silhouettes.
# Switch this block when adding support for other generations.
#
# TODO(trainium3): the chip generation is currently hardcoded to Trainium2.
# When neuron-ls exposes a generation hint (or NEURON_ANATOMY_CHIP_GEN env var
# is provided), select the spec block via lookup so trn3 / trn3u layouts can
# render without source edits. Keep _TRAINIUM2_ENGINE_SPECS as the default to
# preserve current behaviour on existing Trn2 fleets.
_TRAINIUM2_ENGINE_SPECS = ChipEngineSpecs(
    chip_label="Trainium2 chip",
    hbm_stack_count_per_chip=4,
    sram_per_neuroncore_bytes=29_360_128,  # 28 MiB
    neuronlink_intra_label="1024 GB/s",
    engines=[
        EngineSpec(
            name="TensorEngine",
            role="Power-optimised systolic array (GEMM / CONV / Transpose)",
            peak_label="158 cFP8 TFLOPS / 79 BF16 TFLOPS",
        ),
        EngineSpec(
            name="VectorEngine",
            role="Vector ops where each output depends on multiple inputs (LayerNorm, Pooling)",
            peak_label="1 TFLOPS FP32",
        ),
        EngineSpec(
            name="ScalarEngine",
            role="Element-wise scalar ops (activations)",
            peak_label="1.2 TFLOPS FP32",
        ),
        EngineSpec(
            name="GPSIMDEngine",
            role="Eight 512-bit programmable vector processors for custom operators",
            peak_label="programmable",
            sub_lane_count=8,
        ),
    ],
)


async def _run_neuron_ls() -> dict | list:
    if _FAKE:
        return _fake_neuron_ls(_FAKE_VARIANT)

    if not shutil.which(_NEURON_LS_BIN) and not os.path.exists(_NEURON_LS_BIN):
        raise RuntimeError(f"neuron-ls not found at {_NEURON_LS_BIN}")

    proc = await asyncio.create_subprocess_exec(
        _NEURON_LS_BIN,
        "-j",
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await proc.communicate()
    if proc.returncode != 0:
        raise RuntimeError(
            f"neuron-ls -j failed (rc={proc.returncode}): {stderr.decode().strip()[:200]}"
        )
    return json.loads(stdout.decode("utf-8"))


def _normalize(raw: dict | list, instance_type: Optional[str]) -> TopologyResponse:
    """Convert a raw neuron-ls -j payload into TopologyResponse.

    neuron-ls historically alternates between top-level array and
    {"neuron_devices": [...]} formats; both are accepted. Each device
    entry is expected to expose neuron_device, nc_count, memory_size,
    neuroncore_ids, and connected_to.
    """
    devices: list[dict]
    if isinstance(raw, list):
        devices = raw
    elif isinstance(raw, dict):
        devices = raw.get("neuron_devices") or raw.get("devices") or []
    else:
        devices = []

    chips: list[TopologyChip] = []
    edges_seen: set[tuple[int, int]] = set()
    edges: list[TopologyEdge] = []

    for d in devices:
        nd = int(d.get("neuron_device", -1))
        if nd < 0:
            continue
        connected_to = [int(x) for x in d.get("connected_to") or [] if x is not None]
        chips.append(
            TopologyChip(
                neuron_device=nd,
                nc_count=int(d.get("nc_count", 0)),
                neuroncore_ids=[int(x) for x in d.get("neuroncore_ids") or []],
                memory_size=int(d.get("memory_size", 0)),
                connected_to=connected_to,
            )
        )
        for nb in connected_to:
            key = (min(nd, nb), max(nd, nb))
            if key in edges_seen:
                continue
            edges_seen.add(key)
            edges.append(TopologyEdge(src=key[0], dst=key[1]))

    chips.sort(key=lambda c: c.neuron_device)
    nc_per_device = chips[0].nc_count if chips else 0

    return TopologyResponse(
        instance_type=instance_type,
        neuron_device_count=len(chips),
        neuroncore_per_device_count=nc_per_device,
        # Filled in later by monitor.py once neuron_hardware_info arrives
        logical_neuroncore_config=None,
        chips=chips,
        edges=edges,
        chip_engine_specs=_TRAINIUM2_ENGINE_SPECS,
    )


def _fake_neuron_ls(variant: str) -> dict:
    """Return a synthetic neuron-ls -j payload.

    Supported variants:
      - trn2.3xlarge  : 1 chip, no edges, nc_count=4 (LNC=2 default).
      - trn2.48xlarge : 16 chips, 4x4 2D Torus, nc_count=4 per chip.
    """
    if variant == "trn2.3xlarge":
        return {
            "neuron_devices": [
                {
                    "neuron_device": 0,
                    "nc_count": 4,
                    "memory_size": 103_079_215_104,
                    "neuroncore_ids": [0, 1, 2, 3],
                    "connected_to": [],
                }
            ]
        }

    # default: trn2.48xlarge / trn2u.48xlarge with a 4x4 torus.
    devices: list[dict] = []
    for i in range(16):
        row, col = divmod(i, 4)
        nbrs = [
            ((row + 1) % 4) * 4 + col,
            ((row - 1) % 4) * 4 + col,
            row * 4 + (col + 1) % 4,
            row * 4 + (col - 1) % 4,
        ]
        nbrs = sorted(set(nbrs) - {i})
        devices.append(
            {
                "neuron_device": i,
                "nc_count": 4,
                "memory_size": 103_079_215_104,
                "neuroncore_ids": [i * 4 + j for j in range(4)],
                "connected_to": nbrs,
            }
        )
    return {"neuron_devices": devices}


class TopologyCache:
    """In-process cache for `neuron-ls -j`. One read per dashboard process."""

    def __init__(self) -> None:
        self._cached: Optional[TopologyResponse] = None
        self._lock = asyncio.Lock()

    async def get(
        self,
        instance_type_hint: Optional[str] = None,
        *,
        force: bool = False,
    ) -> TopologyResponse:
        async with self._lock:
            if self._cached and not force:
                return self._cached
            raw = await _run_neuron_ls()
            self._cached = _normalize(raw, instance_type_hint)
            log.info(
                "topology refreshed: instance_type=%s chips=%d edges=%d cores_per_chip=%d",
                self._cached.instance_type,
                self._cached.neuron_device_count,
                len(self._cached.edges),
                self._cached.neuroncore_per_device_count,
            )
            return self._cached

    def update_logical_config(self, logical_neuroncore_config: Optional[int]) -> None:
        """Backfill the LNC mode after the first neuron-monitor frame arrives."""
        if self._cached and logical_neuroncore_config is not None:
            self._cached = self._cached.model_copy(
                update={"logical_neuroncore_config": logical_neuroncore_config}
            )

    def update_instance_type(self, instance_type: Optional[str]) -> None:
        if self._cached and instance_type:
            self._cached = self._cached.model_copy(update={"instance_type": instance_type})


topology_cache = TopologyCache()
