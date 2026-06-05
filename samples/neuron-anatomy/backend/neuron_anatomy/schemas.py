"""Public schemas for neuron-anatomy.

These models map 1:1 onto frontend/src/types.ts. The TypeScript side keeps
field names in snake_case so we can swap in OpenAPI codegen later without
re-naming everything.

Design notes:
  - Instance-shape independence. Chip count, NeuronCore count, HBM size,
    NeuronLink topology are all derived from neuron-ls -j and from
    neuron-monitor's neuron_hardware_info. Nothing is hard-coded for any
    particular SKU. trn2.3xlarge (1 chip), trn2.48xlarge (16 chips), and
    Trn2 UltraServer (64 chips) all run through the same code path.
  - Engines (Tensor/Vector/Scalar/GPSIMD) are NOT driven by live telemetry
    because neuron-monitor does not publish per-engine utilisation; we
    expose engine specs as labels only and render them as static
    silhouettes on the frontend.
  - LNC=1 vs LNC=2 is selected via logical_neuroncore_config. The v3d
    sub-core breakdown is populated only when LNC=2.
"""
from __future__ import annotations

from typing import Any, Optional

from pydantic import BaseModel, Field


# ---------------------------------------------------------------------------
# /neuron/topology -- static, read once from neuron-ls -j at startup
# ---------------------------------------------------------------------------


class TopologyEdge(BaseModel):
    """A NeuronLink adjacency, taken from neuron-ls connected_to[]."""

    src: int = Field(..., description="Source chip index (neuron_device)")
    dst: int = Field(..., description="Destination chip index (neuron_device)")


class TopologyChip(BaseModel):
    """Per-chip static information: size, HBM, owned core ids, neighbours."""

    neuron_device: int = Field(..., description="0-origin chip index")
    nc_count: int = Field(
        ...,
        description=(
            "Number of logical NeuronCores this chip exposes. On Trn2 this is 4 "
            "under LNC=2 (default) and 8 under LNC=1. Other SKUs may differ."
        ),
    )
    neuroncore_ids: list[int] = Field(
        ...,
        description="Global logical NeuronCore ids that belong to this chip",
    )
    memory_size: int = Field(..., description="HBM capacity for this chip in bytes")
    connected_to: list[int] = Field(
        default_factory=list,
        description="Neighbour chip indices over NeuronLink",
    )


class TopologyResponse(BaseModel):
    """Returned from GET /neuron/topology. Read once on dashboard load."""

    instance_type: Optional[str] = Field(
        None, description="e.g. 'trn2.48xlarge' (from neuron_hardware_info.instance_info)"
    )
    neuron_device_count: int = Field(..., description="Number of physical chips")
    neuroncore_per_device_count: int = Field(
        ..., description="Logical cores per chip"
    )
    logical_neuroncore_config: Optional[int] = Field(
        None,
        description="Trn2/Trn3 LNC mode (1 or 2). None on devices without LNC.",
    )
    chips: list[TopologyChip]
    edges: list[TopologyEdge] = Field(
        default_factory=list,
        description="Undirected NeuronLink edges (only src<dst is emitted)",
    )
    chip_engine_specs: "ChipEngineSpecs" = Field(
        ...,
        description="Static engine specs used by the frontend silhouettes",
    )


class EngineSpec(BaseModel):
    """Static spec for one engine inside a NeuronCore (no live telemetry)."""

    name: str = Field(..., description="TensorEngine / VectorEngine / ScalarEngine / GPSIMDEngine")
    role: str
    peak_label: Optional[str] = Field(None, description="e.g. '158 cFP8 TFLOPS'")
    sub_lane_count: Optional[int] = Field(
        None,
        description="Number of sub-lanes to draw inside the silhouette (e.g. 8 for GPSIMD)",
    )


class ChipEngineSpecs(BaseModel):
    """Static specs for the chip and its NeuronCore-v3 internals.

    These are not exposed by neuron-monitor, but the frontend wants to
    label its silhouettes with chip-wide constants. Switching SKU
    families (e.g. Trn2 -> Trn3) is a backend-only edit.
    """

    chip_label: str = Field(..., description="e.g. 'Trainium2 chip'")
    hbm_stack_count_per_chip: int = Field(
        ..., description="Physical HBM stack count per chip (Trn2 = 4)"
    )
    sram_per_neuroncore_bytes: int = Field(
        ..., description="On-NeuronCore SBUF (28 MiB = 29360128 bytes)"
    )
    neuronlink_intra_label: Optional[str] = Field(
        None, description="e.g. '1024 GB/s'"
    )
    engines: list[EngineSpec]


# ---------------------------------------------------------------------------
# /neuron/stream (SSE) -- live snapshot pushed every period_s seconds
# ---------------------------------------------------------------------------


class V3dSubCore(BaseModel):
    """Under LNC=2, one logical core hosts two physical NeuronCore-v3 sub-cores."""

    utilisation: float = Field(..., ge=0.0, le=100.0, description="0..100 percent")


class NeuronCoreSample(BaseModel):
    """Live values for one logical NeuronCore."""

    nc_id: int = Field(..., description="Global logical NeuronCore id")
    utilisation: float = Field(
        ..., ge=0.0, le=100.0, description="neuroncore_utilization in percent"
    )
    flops: Optional[float] = Field(None, description="FLOPS over the sample period")
    v3d_sub: Optional[list[V3dSubCore]] = Field(
        None,
        description=(
            "Populated only under LNC=2. Length is 2: [nc_v3.0, nc_v3.1]."
        ),
    )
    memory_used_bytes: Optional[int] = Field(
        None,
        description=(
            "Bytes assigned to this core: sum of constants, model_code, tensors, "
            "scratchpad, and runtime breakdowns reported by neuron-monitor."
        ),
    )


class ChipSample(BaseModel):
    """Live values rolled up to chip granularity."""

    neuron_device: int
    avg_utilisation: float = Field(
        ..., ge=0.0, le=100.0, description="Average utilisation across owned cores"
    )
    hbm_used_bytes: int = Field(..., description="Sum of memory_used_bytes for owned cores")
    hbm_total_bytes: int = Field(..., description="Equals topology.memory_size for the chip")
    ecc_corrected: int = Field(
        0, description="mem_ecc_corrected + sram_ecc_corrected"
    )
    ecc_uncorrected: int = Field(
        0, description="mem_ecc_uncorrected + sram_ecc_uncorrected"
    )


class RuntimeSample(BaseModel):
    """One entry from neuron_runtime_data[] (per-process execution stats)."""

    pid: Optional[int] = None
    tag: Optional[str] = None
    error_summary: dict[str, int] = Field(default_factory=dict)
    latency_p50_ms: Optional[float] = None
    latency_p99_ms: Optional[float] = None


class VcpuUsage(BaseModel):
    """vCPU usage rolled up across all logical CPUs."""

    user: float = Field(..., ge=0.0, le=100.0, description="user-mode percent")
    system: float = Field(..., ge=0.0, le=100.0, description="kernel-mode percent")
    idle: float = Field(..., ge=0.0, le=100.0)
    io_wait: float = Field(0.0, ge=0.0, le=100.0)
    irq: float = Field(0.0, ge=0.0, le=100.0)
    soft_irq: float = Field(0.0, ge=0.0, le=100.0)


class HostMemory(BaseModel):
    """System-wide host memory + neuron-runtime host-side breakdown.

    Fields mirror neuron-monitor:
      - memory_total_bytes / memory_used_bytes come from system_data.memory_info
      - tensors / constants / dma_buffers / application_memory come from
        neuron_runtime_data[].report.memory_used.usage_breakdown.host
    """

    total_bytes: int = Field(..., description="Total host RAM (memory_info.memory_total_bytes)")
    used_bytes: int = Field(..., description="System used host RAM (memory_info.memory_used_bytes)")
    tensors_bytes: int = Field(0, description="Runtime tensors in host RAM")
    constants_bytes: int = Field(0, description="Runtime constants in host RAM")
    dma_buffers_bytes: int = Field(0, description="DMA buffers")
    application_memory_bytes: int = Field(0, description="Other process app memory")


class DeviceMemory(BaseModel):
    """Aggregate device (HBM) memory breakdown across all NeuronCores.

    Fields mirror the per-NeuronCore neuron_runtime_used_bytes.usage_breakdown
    summed across cores. total_bytes / used_bytes come from topology +
    neuron_runtime_used_bytes.neuron_device.
    """

    total_bytes: int = Field(..., description="Total HBM across all chips")
    used_bytes: int = Field(..., description="Sum of neuron_device used bytes")
    tensors_bytes: int = Field(0)
    constants_bytes: int = Field(0)
    model_code_bytes: int = Field(0)
    runtime_memory_bytes: int = Field(0)
    model_shared_scratchpad_bytes: int = Field(0)


class SystemStats(BaseModel):
    """Host- and runtime-level stats that complement the chip view.

    All values are derived from neuron-monitor's system_metrics +
    neuron_runtime_data[].report.{vcpu_usage,memory_used}.
    """

    system_vcpu: Optional[VcpuUsage] = Field(
        None,
        description=(
            "system_data.vcpu_usage.average_usage. Reflects ALL processes on the host."
        ),
    )
    runtime_vcpu: Optional[VcpuUsage] = Field(
        None,
        description=(
            "neuron_runtime_data[0].report.vcpu_usage.average_usage. Reflects only "
            "the neuron-runtime processes."
        ),
    )
    host_memory: Optional[HostMemory] = None
    device_memory: Optional[DeviceMemory] = None


class Snapshot(BaseModel):
    """Single snapshot emitted over SSE.

    A neuron-monitor JSON line is normalised here so the frontend can render
    immediately. Keeping the wire format separate from neuron-monitor's raw
    schema lets us absorb upstream field renames in the backend only.
    """

    ts_ms: int
    available: bool = True
    chips: list[ChipSample]
    cores: list[NeuronCoreSample]
    runtimes: list[RuntimeSample] = Field(default_factory=list)
    system: Optional[SystemStats] = Field(
        None,
        description="Host vCPU + memory rollup. Absent until first sample arrives.",
    )
    raw: Optional[dict[str, Any]] = Field(
        None,
        description=(
            "Raw neuron-monitor JSON line, included only when "
            "NEURON_ANATOMY_INCLUDE_RAW=1 is set. Useful for debugging."
        ),
    )


class HealthResponse(BaseModel):
    status: str
    monitor_running: bool
    last_snapshot_age_ms: Optional[int] = None
    instance_type: Optional[str] = None


# pydantic v2 forward-ref resolution
TopologyResponse.model_rebuild()
