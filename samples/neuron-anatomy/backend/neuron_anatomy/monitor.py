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
    DeviceMemory,
    HostMemory,
    NeuronCoreSample,
    RuntimeSample,
    Snapshot,
    SystemStats,
    V3dSubCore,
    VcpuUsage,
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
                    # Per-runtime vCPU rollup. neuron-monitor calls this
                    # "neuron_runtime_vcpu_usage" (different from the
                    # system_metrics "vcpu_usage"); the config validator
                    # rejects "vcpu_usage" inside neuron_runtimes.
                    {"type": "neuron_runtime_vcpu_usage"},
                ],
            }
        ],
        # neuron_hardware_info is not available as a system metric on the
        # currently installed neuron-monitor (Neuron 2.x reports
        # "available: vcpu_usage, memory_info, self_stats, neuron_hw_counters").
        # The instance/topology info we used to derive from it is now
        # picked up from neuron-ls -j at startup, so dropping it here
        # has no functional impact.
        "system_metrics": [
            {"type": "vcpu_usage"},
            {"type": "memory_info"},
            {"period": f"{_NEURON_MONITOR_PERIOD_S}s", "type": "neuron_hw_counters"},
        ],
    }
    return json.dumps(cfg)


def _summarize_runtime(runtime: dict[str, Any]) -> RuntimeSample:
    report = runtime.get("report") or {}
    exec_stats = report.get("execution_stats") or {}
    err = exec_stats.get("error_summary") or {}
    latency = exec_stats.get("latency_stats") or {}
    # `device_latency` is sometimes present but null (no recent inference);
    # fall back to {} so the .get("p50") below cannot throw.
    device_latency = latency.get("device_latency") or {}
    return RuntimeSample(
        pid=runtime.get("pid"),
        tag=runtime.get("tag"),
        error_summary={k: int(v) for k, v in err.items() if isinstance(v, (int, float))},
        latency_p50_ms=_seconds_to_ms(device_latency.get("p50")),
        latency_p99_ms=_seconds_to_ms(device_latency.get("p99")),
    )


def _seconds_to_ms(v: Any) -> Optional[float]:
    if v is None:
        return None
    try:
        return float(v) * 1000.0
    except (TypeError, ValueError):
        return None


def _extract_cores(runtime_data: list[dict[str, Any]]) -> list[NeuronCoreSample]:
    """Aggregate neuron_runtime_data[].report.neuroncore_counters.neuroncores_in_use.

    A given logical NeuronCore is owned by at most one runtime in any sane
    deployment, but neuron-monitor still reports the same nc id from every
    runtime when its tag_filter matches them all (each runtime emits zeros
    for cores it does not own). The previous "max utilisation wins" rule
    therefore worked for utilisation but silently dropped the *non-zero*
    memory_used_bytes from the runtime that actually owns the core.
    Iterate twice instead: pick the runtime that reports non-zero util OR
    non-zero memory and merge per-field, falling back to zeros only when
    no runtime reports anything.
    """
    out: dict[int, NeuronCoreSample] = {}
    # nc_id -> (util, flops, v3d_sub, memory_used_bytes)
    aggregated: dict[int, dict[str, Any]] = {}
    for runtime in runtime_data or []:
        report = runtime.get("report") or {}
        ncc = (report.get("neuroncore_counters") or {}).get("neuroncores_in_use") or {}
        memory_used = report.get("memory_used") or {}
        used_bytes = memory_used.get("neuron_runtime_used_bytes") or {}
        usage_breakdown = used_bytes.get("usage_breakdown") or {}
        mem_used_breakdown = usage_breakdown.get("neuroncore_memory_usage") or {}
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
            )

            cur = aggregated.setdefault(
                nc_id,
                {"util": 0.0, "flops": None, "v3d_sub": None, "mem": 0},
            )
            # utilisation: max across runtimes (only one runtime should
            # actually be non-zero, but be defensive)
            if util > cur["util"]:
                cur["util"] = util
                cur["flops"] = (
                    float(flops) if isinstance(flops, (int, float)) else cur["flops"]
                )
                if v3d_sub:
                    cur["v3d_sub"] = v3d_sub
            elif cur["v3d_sub"] is None and v3d_sub:
                cur["v3d_sub"] = v3d_sub
            # memory: take the largest non-zero report. The "owning"
            # runtime fills it in; sibling runtimes fill in zeros.
            if mem_total > cur["mem"]:
                cur["mem"] = mem_total

    for nc_id, agg in aggregated.items():
        out[nc_id] = NeuronCoreSample(
            nc_id=nc_id,
            utilisation=agg["util"],
            flops=agg["flops"],
            v3d_sub=agg["v3d_sub"],
            memory_used_bytes=agg["mem"] or None,
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


def _vcpu_from_average(payload: Any) -> Optional[VcpuUsage]:
    """Build VcpuUsage from neuron-monitor's `average_usage` block.

    Two shapes appear in the wild:
      - system_data.vcpu_usage:
          { period, average_usage: {user, system, idle, io_wait, irq, soft_irq}, usage_data: ... }
        -> read from .average_usage
      - neuron_runtime_data[].report.neuron_runtime_vcpu_usage:
          { period, vcpu_usage: {user, system}, error }
        -> read from .vcpu_usage (only user/system; idle is implied)
    Both go through this helper.
    """
    if not isinstance(payload, dict):
        return None
    block = payload.get("average_usage")
    if not isinstance(block, dict):
        block = payload.get("vcpu_usage")
    if not isinstance(block, dict):
        return None
    try:
        user = float(block.get("user", 0.0))
        sysm = float(block.get("system", 0.0))
        # `idle` is only present in the system_data shape. For runtime
        # vcpu, infer idle from busy so the bar still adds up to 100%.
        if "idle" in block:
            idle = float(block["idle"])
        else:
            idle = max(0.0, 100.0 - user - sysm)
        return VcpuUsage(
            user=user,
            system=sysm,
            idle=idle,
            io_wait=float(block.get("io_wait", 0.0)),
            irq=float(block.get("irq", 0.0)),
            soft_irq=float(block.get("soft_irq", 0.0)),
        )
    except (TypeError, ValueError):
        return None


def _extract_system(
    raw: dict[str, Any],
    runtime_data: list[dict[str, Any]],
    chips: list[ChipSample],
) -> SystemStats:
    """Pull host vCPU + memory rollup out of the same neuron-monitor frame.

    Sources:
      system_data.vcpu_usage             -> system_vcpu (all processes)
      system_data.memory_info            -> host_memory total/used
      neuron_runtime_data[].vcpu_usage   -> runtime_vcpu (neuron-runtime processes)
      neuron_runtime_data[].memory_used  -> host/device breakdowns
    """
    sd = raw.get("system_data") or {}
    system_vcpu = _vcpu_from_average(sd.get("vcpu_usage"))
    mem_info = sd.get("memory_info") or {}
    host_total = int(mem_info.get("memory_total_bytes") or 0)
    host_used = int(mem_info.get("memory_used_bytes") or 0)

    # Aggregate across runtimes. Multiple neuron-runtime processes are rare
    # but legal (e.g. one per model server). Sum their breakdowns and pick
    # the runtime with the highest user-mode CPU as the "primary" for the
    # vCPU bar — averaging would smear a busy runtime under idle ones.
    runtime_vcpu: Optional[VcpuUsage] = None
    best_user = -1.0
    host_tensors = host_consts = host_dma = host_app = 0
    dev_tensors = dev_consts = dev_code = dev_runtime = dev_scratch = 0
    for runtime in runtime_data or []:
        report = runtime.get("report") or {}
        # neuron-monitor publishes per-runtime CPU usage under
        # `neuron_runtime_vcpu_usage` (the metric name configured in the
        # JSON). The block inside is `vcpu_usage: {user, system}` rather
        # than the system-wide `average_usage` shape.
        rv = _vcpu_from_average(report.get("neuron_runtime_vcpu_usage"))
        if rv is not None and rv.user > best_user:
            runtime_vcpu = rv
            best_user = rv.user
        used_bytes = (
            (report.get("memory_used") or {}).get("neuron_runtime_used_bytes") or {}
        )
        host_bd = (used_bytes.get("usage_breakdown") or {}).get("host") or {}
        host_tensors += int(host_bd.get("tensors", 0) or 0)
        host_consts += int(host_bd.get("constants", 0) or 0)
        host_dma += int(host_bd.get("dma_buffers", 0) or 0)
        host_app += int(host_bd.get("application_memory", 0) or 0)
        ncm = (used_bytes.get("usage_breakdown") or {}).get(
            "neuroncore_memory_usage"
        ) or {}
        for _, per_core in ncm.items():
            if not isinstance(per_core, dict):
                continue
            dev_tensors += int(per_core.get("tensors", 0) or 0)
            dev_consts += int(per_core.get("constants", 0) or 0)
            dev_code += int(per_core.get("model_code", 0) or 0)
            dev_runtime += int(per_core.get("runtime_memory", 0) or 0)
            dev_scratch += int(per_core.get("model_shared_scratchpad", 0) or 0)

    host_memory = HostMemory(
        total_bytes=host_total,
        used_bytes=host_used,
        tensors_bytes=host_tensors,
        constants_bytes=host_consts,
        dma_buffers_bytes=host_dma,
        application_memory_bytes=host_app,
    )

    # Device totals: sum chips' HBM capacity for total, and sum the per-core
    # breakdown for used (so the bar adds up to the same number the chip
    # tiles' hbm_used_bytes sum to).
    dev_total = sum(c.hbm_total_bytes for c in chips)
    dev_used = (
        dev_tensors + dev_consts + dev_code + dev_runtime + dev_scratch
    )
    device_memory = DeviceMemory(
        total_bytes=dev_total,
        used_bytes=dev_used,
        tensors_bytes=dev_tensors,
        constants_bytes=dev_consts,
        model_code_bytes=dev_code,
        runtime_memory_bytes=dev_runtime,
        model_shared_scratchpad_bytes=dev_scratch,
    )

    return SystemStats(
        system_vcpu=system_vcpu,
        runtime_vcpu=runtime_vcpu,
        host_memory=host_memory,
        device_memory=device_memory,
    )


def _normalize_line(raw: dict[str, Any]) -> Snapshot:
    runtimes_data = raw.get("neuron_runtime_data") or []
    cores = _extract_cores(runtimes_data)
    chips = _extract_chips(cores, raw)
    runtimes = [_summarize_runtime(r) for r in runtimes_data]
    system = _extract_system(raw, runtimes_data, chips)

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
        system=system,
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
        # Backoff between failures: start at 5 s and grow up to 60 s so a
        # broken setup does not flood the journal with restart spam.
        backoff = 5.0
        while not self._stopped.is_set():
            try:
                if _FAKE:
                    await self._run_fake()
                else:
                    await self._run_real()
                # Successful exit (e.g. neuron-monitor terminated cleanly):
                # reset the backoff before the next loop.
                backoff = 5.0
            except asyncio.CancelledError:
                raise
            except Exception:  # noqa: BLE001
                log.exception("neuron-monitor loop crashed; retry in %.0fs", backoff)
                await asyncio.sleep(backoff)
                backoff = min(backoff * 2, 60.0)

    async def _run_real(self) -> None:
        if not (shutil.which(_NEURON_MONITOR_BIN) or os.path.exists(_NEURON_MONITOR_BIN)):
            log.error("neuron-monitor binary not found at %s; sleeping", _NEURON_MONITOR_BIN)
            await asyncio.sleep(10.0)
            return

        # Write the config to a path that survives systemd PrivateTmp=true
        # by writing it into the working directory rather than /tmp. The
        # working directory belongs to the unit user so this is writable.
        cfg_path = os.environ.get(
            "NEURON_ANATOMY_MONITOR_CFG",
            os.path.join(os.getcwd(), "neuron-anatomy-monitor.json"),
        )
        try:
            with open(cfg_path, "w", encoding="utf-8") as fh:
                fh.write(_build_config_json())
        except OSError as exc:
            log.error("failed to write neuron-monitor config to %s: %s", cfg_path, exc)
            await asyncio.sleep(10.0)
            return

        log.info("spawning %s -c %s", _NEURON_MONITOR_BIN, cfg_path)
        self._proc = await asyncio.create_subprocess_exec(
            _NEURON_MONITOR_BIN,
            "-c",
            cfg_path,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        assert self._proc.stdout is not None

        # Default StreamReader buffer is 64 KiB; neuron-monitor regularly
        # emits JSON lines larger than that on trn2.48xlarge with many
        # loaded models. Bump the limit on the existing reader so
        # readline() does not raise "Separator is found, but chunk is
        # longer than limit".
        try:
            self._proc.stdout._limit = 64 * 1024 * 1024  # type: ignore[attr-defined]
        except Exception:  # noqa: BLE001
            pass

        # Drain stderr in the background so a chatty tool cannot fill the
        # pipe and block the producer; surface any messages in the journal.
        async def _drain_stderr() -> None:
            assert self._proc is not None and self._proc.stderr is not None
            async for raw_line in self._proc.stderr:
                msg = raw_line.decode("utf-8", errors="replace").strip()
                if msg:
                    log.warning("neuron-monitor stderr: %s", msg[:300])

        stderr_task = asyncio.create_task(_drain_stderr())

        # Read raw chunks instead of readline() to avoid asyncio's per-line
        # buffer limit even after raising _limit. Lines are split on '\n'
        # in user space and any trailing partial line is carried over.
        try:
            buf = bytearray()
            while not self._stopped.is_set():
                chunk = await self._proc.stdout.read(65536)
                if not chunk:
                    break
                buf.extend(chunk)
                # Drain every complete line in the buffer.
                while True:
                    nl = buf.find(b"\n")
                    if nl < 0:
                        break
                    line_bytes = bytes(buf[:nl])
                    del buf[: nl + 1]
                    text = line_bytes.decode("utf-8", errors="replace").strip()
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
        finally:
            stderr_task.cancel()
            try:
                await stderr_task
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass

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
            # Fake but visually plausible host stats so the new system
            # panel has something to render in offline dev runs.
            cpu_user = 12.0 + 5.0 * math.sin(t * 0.4)
            cpu_sys = 4.0 + 2.0 * math.cos(t * 0.3)
            sys_vcpu = VcpuUsage(
                user=max(0.0, cpu_user),
                system=max(0.0, cpu_sys),
                idle=max(0.0, 100.0 - cpu_user - cpu_sys),
            )
            rt_vcpu = VcpuUsage(
                user=max(0.0, cpu_user * 0.4),
                system=max(0.0, cpu_sys * 0.6),
                idle=max(0.0, 100.0 - cpu_user * 0.4 - cpu_sys * 0.6),
            )
            host_total = 192 * 1024 ** 3
            host_used = int(host_total * (0.20 + 0.05 * math.sin(t * 0.2)))
            dev_used_per_core = int(20_000_000 + 5_000_000 * math.sin(t * 0.3))
            num_cores = sum(len(c.neuroncore_ids) for c in topology_cache._cached.chips) if topology_cache._cached else 0
            system = SystemStats(
                system_vcpu=sys_vcpu,
                runtime_vcpu=rt_vcpu,
                host_memory=HostMemory(
                    total_bytes=host_total,
                    used_bytes=host_used,
                    tensors_bytes=int(host_used * 0.05),
                    constants_bytes=int(host_used * 0.10),
                    dma_buffers_bytes=int(host_used * 0.02),
                    application_memory_bytes=int(host_used * 0.83),
                ),
                device_memory=DeviceMemory(
                    total_bytes=sum(c.hbm_total_bytes for c in chips),
                    used_bytes=dev_used_per_core * num_cores,
                    tensors_bytes=int(dev_used_per_core * num_cores * 0.55),
                    constants_bytes=int(dev_used_per_core * num_cores * 0.08),
                    model_code_bytes=int(dev_used_per_core * num_cores * 0.12),
                    runtime_memory_bytes=int(dev_used_per_core * num_cores * 0.05),
                    model_shared_scratchpad_bytes=int(dev_used_per_core * num_cores * 0.20),
                ),
            )
            snap = Snapshot(
                ts_ms=int(time.time() * 1000),
                available=True,
                chips=chips,
                cores=cores,
                runtimes=[],
                system=system,
                raw=None,
            )
            await self._publish(snap)
            t += 0.1
            await asyncio.sleep(float(_NEURON_MONITOR_PERIOD_S))


monitor_service = MonitorService()
