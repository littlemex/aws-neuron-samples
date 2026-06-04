"""Run neuron-monitor as a subprocess and stream its newline-delimited JSON.

Design:
  - Exactly one neuron-monitor process per OS instance. Multiple sample
    apps that link this library should reuse the same backend.
  - The latest snapshot lives in an asyncio.Lock-protected dict. GET
    /neuron/snapshot returns a copy immediately.
  - SSE delivery uses pub/sub: each subscriber gets its own asyncio.Queue
    capped at maxsize and we drop oldest-on-overflow (latest-wins). Slow
    clients therefore cannot apply backpressure to the producer.
  - We never push neuron-monitor's raw JSON to the frontend; everything
    is normalised into Snapshot first so upstream field renames stay
    contained to this module.

LNC handling:
  - The first frame's neuron_hardware_info.logical_neuroncore_config is
    pushed into the topology cache. Frontend reads /neuron/topology for
    the LNC=1 vs LNC=2 decision, so it does not need to peek into the
    snapshot for that.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import shutil
import time
from typing import Any, Optional

from .schemas import (
    ChipSample,
    NeuronCoreSample,
    RuntimeSample,
    Snapshot,
    V3dSubCore,
)
from .topology import topology_cache

log = logging.getLogger("neuron-anatomy.monitor")


_NEURON_MONITOR_BIN = os.environ.get("NEURON_MONITOR_BIN", "/opt/aws/neuron/bin/neuron-monitor")
_NEURON_MONITOR_PERIOD_S = os.environ.get("NEURON_MONITOR_PERIOD_S", "1")
_INCLUDE_RAW = os.environ.get("NEURON_ANATOMY_INCLUDE_RAW", "0") == "1"
_FAKE = os.environ.get("NEURON_ANATOMY_FAKE_MONITOR", "0") == "1"


def _build_config_json() -> str:
    """Build the JSON config that we hand to `neuron-monitor -c`."""
    cfg = {
        "period": f"{_NEURON_MONITOR_PERIOD_S}s",
        "neuron_runtimes": [
            {
                "tag_filter": ".*",
                "metrics": [
                    {"type": "neuroncore_counters"},
                    {"type": "memory_used"},
                    {"type": "execution_stats"},
                ],
            }
        ],
        "system_metrics": [
            {"type": "vcpu_usage"},
            {"type": "memory_info"},
            {"period": f"{_NEURON_MONITOR_PERIOD_S}s", "type": "neuron_hw_counters"},
            {"type": "neuron_hardware_info"},
        ],
    }
    return json.dumps(cfg)


def _summarize_runtime(runtime: dict[str, Any]) -> RuntimeSample:
    report = runtime.get("report") or {}
    exec_stats = report.get("execution_stats") or {}
    err = exec_stats.get("error_summary") or {}
    latency = exec_stats.get("latency_stats") or {}
    return RuntimeSample(
        pid=runtime.get("pid"),
        tag=runtime.get("tag"),
        error_summary={k: int(v) for k, v in err.items() if isinstance(v, (int, float))},
        latency_p50_ms=_seconds_to_ms(latency.get("device_latency", {}).get("p50")),
        latency_p99_ms=_seconds_to_ms(latency.get("device_latency", {}).get("p99")),
    )


def _seconds_to_ms(v: Any) -> Optional[float]:
    if v is None:
        return None
    try:
        return float(v) * 1000.0
    except (TypeError, ValueError):
        return None


def _extract_cores(runtime_data: list[dict[str, Any]]) -> list[NeuronCoreSample]:
    """Aggregate neuron_runtime_data[].report.neuroncore_counters.neuroncores_in_use."""
    out: dict[int, NeuronCoreSample] = {}
    for runtime in runtime_data or []:
        report = runtime.get("report") or {}
        ncc = (report.get("neuroncore_counters") or {}).get("neuroncores_in_use") or {}
        mem_used_breakdown = (
            (report.get("memory_used") or {})
            .get("neuron_runtime_used_bytes", {})
            .get("usage_breakdown", {})
            .get("neuroncore_memory_usage", {})
        )
        for nc_key, payload in ncc.items():
            try:
                nc_id = int(nc_key)
            except (TypeError, ValueError):
                continue
            util = float(payload.get("neuroncore_utilization", 0.0))
            flops = payload.get("flops")
            v3d = payload.get("v3d")
            v3d_sub: Optional[list[V3dSubCore]] = None
            if isinstance(v3d, dict):
                # Order: v3d.nc_v3.0 then v3d.nc_v3.1
                nc_v3 = v3d.get("nc_v3") or {}
                subs = []
                for k in ("0", "1"):
                    p = nc_v3.get(k)
                    if isinstance(p, dict):
                        subs.append(
                            V3dSubCore(
                                utilisation=float(p.get("neuroncore_utilization", 0.0))
                            )
                        )
                if subs:
                    v3d_sub = subs

            mem_for_core = mem_used_breakdown.get(str(nc_id)) or {}
            mem_total = sum(
                int(v) for v in mem_for_core.values() if isinstance(v, (int, float))
            ) or None

            # When the same nc id appears under multiple runtimes, keep the
            # busier entry (max utilisation).
            existing = out.get(nc_id)
            if existing and existing.utilisation >= util:
                continue
            out[nc_id] = NeuronCoreSample(
                nc_id=nc_id,
                utilisation=util,
                flops=float(flops) if isinstance(flops, (int, float)) else None,
                v3d_sub=v3d_sub,
                memory_used_bytes=mem_total,
            )
    return [out[k] for k in sorted(out.keys())]


def _extract_chips(
    cores: list[NeuronCoreSample],
    raw: dict[str, Any],
) -> list[ChipSample]:
    """Aggregate per-core values into per-chip samples.

    neuron-monitor does not publish utilisation at chip granularity, so we
    derive it from the cores using the topology cache's neuroncore_ids
    grouping. If the topology cache has not been primed yet (very first
    iteration of the monitor loop) we return an empty list.
    """
    topo = topology_cache._cached  # private read; only refreshed at startup
    if not topo:
        return []
    by_id = {c.nc_id: c for c in cores}
    hw_counters = (
        (raw.get("system_data") or {}).get("neuron_hw_counters") or {}
    ) or {}
    devices_hw = hw_counters.get("neuron_devices") or []
    ecc_lookup: dict[int, dict[str, int]] = {}
    for d in devices_hw:
        idx = d.get("neuron_device_index")
        if idx is None:
            continue
        try:
            ecc_lookup[int(idx)] = {
                "corrected": int(d.get("mem_ecc_corrected", 0))
                + int(d.get("sram_ecc_corrected", 0)),
                "uncorrected": int(d.get("mem_ecc_uncorrected", 0))
                + int(d.get("sram_ecc_uncorrected", 0)),
            }
        except (TypeError, ValueError):
            pass

    out: list[ChipSample] = []
    for chip in topo.chips:
        chip_cores = [by_id.get(nc) for nc in chip.neuroncore_ids]
        live_cores = [c for c in chip_cores if c is not None]
        avg = (
            sum(c.utilisation for c in live_cores) / len(live_cores)
            if live_cores
            else 0.0
        )
        hbm_used = sum(c.memory_used_bytes or 0 for c in live_cores)
        ecc = ecc_lookup.get(chip.neuron_device, {})
        out.append(
            ChipSample(
                neuron_device=chip.neuron_device,
                avg_utilisation=avg,
                hbm_used_bytes=hbm_used,
                hbm_total_bytes=chip.memory_size,
                ecc_corrected=ecc.get("corrected", 0),
                ecc_uncorrected=ecc.get("uncorrected", 0),
            )
        )
    return out


def _normalize_line(raw: dict[str, Any]) -> Snapshot:
    runtimes_data = raw.get("neuron_runtime_data") or []
    cores = _extract_cores(runtimes_data)
    chips = _extract_chips(cores, raw)
    runtimes = [_summarize_runtime(r) for r in runtimes_data]

    # If neuron_hardware_info is present, refresh the topology cache.
    hw = raw.get("neuron_hardware_info") or {}
    if hw:
        topology_cache.update_logical_config(hw.get("logical_neuroncore_config"))
        instance_info = (raw.get("instance_info") or {})
        topology_cache.update_instance_type(instance_info.get("instance_type"))

    return Snapshot(
        ts_ms=int(time.time() * 1000),
        available=True,
        chips=chips,
        cores=cores,
        runtimes=runtimes,
        raw=raw if _INCLUDE_RAW else None,
    )


class MonitorService:
    """Long-lived neuron-monitor reader with SSE pub/sub. One per process."""

    def __init__(self) -> None:
        self._latest: Optional[Snapshot] = None
        self._lock = asyncio.Lock()
        self._task: Optional[asyncio.Task] = None
        self._proc: Optional[asyncio.subprocess.Process] = None
        self._subscribers: set[asyncio.Queue[Snapshot]] = set()
        self._stopped = asyncio.Event()
        self._last_update_ms: Optional[int] = None

    async def start(self) -> None:
        if self._task and not self._task.done():
            return
        self._stopped.clear()
        self._task = asyncio.create_task(self._run(), name="neuron-anatomy-monitor")
        log.info("MonitorService.start (fake=%s)", _FAKE)

    async def stop(self) -> None:
        self._stopped.set()
        if self._proc and self._proc.returncode is None:
            try:
                self._proc.terminate()
            except ProcessLookupError:
                pass
        if self._task:
            try:
                await asyncio.wait_for(self._task, timeout=5.0)
            except asyncio.TimeoutError:
                self._task.cancel()

    async def latest(self) -> Optional[Snapshot]:
        async with self._lock:
            return self._latest

    def is_running(self) -> bool:
        return bool(self._task and not self._task.done())

    def last_update_age_ms(self) -> Optional[int]:
        if self._last_update_ms is None:
            return None
        return max(0, int(time.time() * 1000) - self._last_update_ms)

    def subscribe(self) -> asyncio.Queue[Snapshot]:
        q: asyncio.Queue[Snapshot] = asyncio.Queue(maxsize=4)
        self._subscribers.add(q)
        return q

    def unsubscribe(self, q: asyncio.Queue[Snapshot]) -> None:
        self._subscribers.discard(q)

    async def _publish(self, snap: Snapshot) -> None:
        async with self._lock:
            self._latest = snap
            self._last_update_ms = snap.ts_ms
        for q in list(self._subscribers):
            try:
                q.put_nowait(snap)
            except asyncio.QueueFull:
                # Latest-wins: drop one stale entry and try again.
                try:
                    q.get_nowait()
                except asyncio.QueueEmpty:
                    pass
                try:
                    q.put_nowait(snap)
                except asyncio.QueueFull:
                    pass

    async def _run(self) -> None:
        while not self._stopped.is_set():
            try:
                if _FAKE:
                    await self._run_fake()
                else:
                    await self._run_real()
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                log.exception("neuron-monitor loop crashed; retry in 3s")
                await asyncio.sleep(3.0)

    async def _run_real(self) -> None:
        if not (shutil.which(_NEURON_MONITOR_BIN) or os.path.exists(_NEURON_MONITOR_BIN)):
            log.error("neuron-monitor binary not found at %s; sleeping", _NEURON_MONITOR_BIN)
            await asyncio.sleep(10.0)
            return

        cfg_path = "/tmp/neuron-anatomy-monitor.json"
        with open(cfg_path, "w", encoding="utf-8") as fh:
            fh.write(_build_config_json())

        log.info("spawning %s -c %s", _NEURON_MONITOR_BIN, cfg_path)
        self._proc = await asyncio.create_subprocess_exec(
            _NEURON_MONITOR_BIN,
            "-c",
            cfg_path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        assert self._proc.stdout is not None
        async for line in self._proc.stdout:
            if self._stopped.is_set():
                break
            text = line.decode("utf-8", errors="replace").strip()
            if not text:
                continue
            try:
                raw = json.loads(text)
            except json.JSONDecodeError:
                log.debug("non-json line: %s", text[:120])
                continue
            try:
                snap = _normalize_line(raw)
            except Exception:  # noqa: BLE001
                log.exception("failed to normalize neuron-monitor line")
                continue
            await self._publish(snap)

        rc = await self._proc.wait()
        log.warning("neuron-monitor exited with rc=%s", rc)

    async def _run_fake(self) -> None:
        """Synthetic Trn2-flavoured waveform for offline development."""
        import math
        import random

        # Prime the topology cache once so chip-level aggregation works.
        await topology_cache.get(instance_type_hint=os.environ.get("NEURON_ANATOMY_FAKE_VARIANT", "trn2.48xlarge-fake"))
        topology_cache.update_logical_config(2)
        t = 0.0
        while not self._stopped.is_set():
            cores: list[NeuronCoreSample] = []
            for chip in topology_cache._cached.chips if topology_cache._cached else []:
                for nc_id in chip.neuroncore_ids:
                    base = 50.0 + 40.0 * math.sin(t + nc_id * 0.4)
                    util = max(0.0, min(100.0, base + random.uniform(-5, 5)))
                    cores.append(
                        NeuronCoreSample(
                            nc_id=nc_id,
                            utilisation=util,
                            flops=1e12 * util / 100,
                            v3d_sub=[
                                V3dSubCore(utilisation=max(0.0, min(100.0, util + random.uniform(-8, 8)))),
                                V3dSubCore(utilisation=max(0.0, min(100.0, util + random.uniform(-8, 8)))),
                            ],
                            memory_used_bytes=int(20_000_000 + 5_000_000 * math.sin(t * 0.3 + nc_id)),
                        )
                    )
            chips = _extract_chips(cores, raw={})
            snap = Snapshot(
                ts_ms=int(time.time() * 1000),
                available=True,
                chips=chips,
                cores=cores,
                runtimes=[],
                raw=None,
            )
            await self._publish(snap)
            t += 0.1
            await asyncio.sleep(float(_NEURON_MONITOR_PERIOD_S))


monitor_service = MonitorService()
