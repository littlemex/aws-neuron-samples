"""Unit tests for monitor._normalize_line / _extract_chips.

These run without an actual Neuron-equipped host. A neuron-monitor JSON
fragment is provided as a fixture and converted through the same normaliser
that the production loop uses.
"""
from __future__ import annotations

import pytest

from neuron_anatomy import schemas
from neuron_anatomy.monitor import _extract_chips, _extract_cores
from neuron_anatomy.topology import topology_cache


@pytest.mark.asyncio
async def test_extract_cores_lnc2_v3d_split() -> None:
    raw = [
        {
            "report": {
                "neuroncore_counters": {
                    "neuroncores_in_use": {
                        "0": {
                            "neuroncore_utilization": 87.5,
                            "flops": 1.5e12,
                            "v3d": {
                                "nc_v3": {
                                    "0": {"neuroncore_utilization": 90.0},
                                    "1": {"neuroncore_utilization": 85.0},
                                }
                            },
                        }
                    }
                },
                "memory_used": {
                    "neuron_runtime_used_bytes": {
                        "usage_breakdown": {
                            "neuroncore_memory_usage": {
                                "0": {"constants": 1_000_000, "tensors": 2_000_000}
                            }
                        }
                    }
                },
            }
        }
    ]

    cores = _extract_cores(raw)
    assert len(cores) == 1
    assert cores[0].nc_id == 0
    assert cores[0].utilisation == pytest.approx(87.5)
    assert cores[0].v3d_sub is not None and len(cores[0].v3d_sub) == 2
    assert cores[0].v3d_sub[0].utilisation == pytest.approx(90.0)
    assert cores[0].memory_used_bytes == 3_000_000


@pytest.mark.asyncio
async def test_extract_chips_uses_topology_neuroncore_ids(monkeypatch: pytest.MonkeyPatch) -> None:
    # Prime a fake topology, then verify chip-level aggregation.
    monkeypatch.setenv("NEURON_ANATOMY_FAKE_TOPOLOGY", "1")
    monkeypatch.setenv("NEURON_ANATOMY_FAKE_VARIANT", "trn2.48xlarge")
    topo = await topology_cache.get(force=True)
    assert topo.neuron_device_count == 16
    cores = [
        schemas.NeuronCoreSample(nc_id=nc_id, utilisation=50.0, memory_used_bytes=1_000_000)
        for chip in topo.chips
        for nc_id in chip.neuroncore_ids
    ]
    chips = _extract_chips(cores, raw={})
    assert len(chips) == 16
    assert all(c.avg_utilisation == 50.0 for c in chips)
    assert all(c.hbm_used_bytes == 4_000_000 for c in chips)  # 4 cores per chip
    assert all(c.hbm_total_bytes == 103_079_215_104 for c in chips)


@pytest.mark.asyncio
async def test_extract_chips_3xlarge_single_chip(monkeypatch: pytest.MonkeyPatch) -> None:
    """Single-chip variant: edges empty, one chip with 4 cores."""
    monkeypatch.setenv("NEURON_ANATOMY_FAKE_TOPOLOGY", "1")
    monkeypatch.setenv("NEURON_ANATOMY_FAKE_VARIANT", "trn2.3xlarge")
    topo = await topology_cache.get(force=True)
    assert topo.neuron_device_count == 1
    assert len(topo.edges) == 0
    assert topo.chips[0].nc_count == 4
    cores = [
        schemas.NeuronCoreSample(nc_id=nc_id, utilisation=33.3, memory_used_bytes=2_000_000)
        for nc_id in topo.chips[0].neuroncore_ids
    ]
    chips = _extract_chips(cores, raw={})
    assert len(chips) == 1
    assert chips[0].avg_utilisation == pytest.approx(33.3)
    assert chips[0].hbm_used_bytes == 8_000_000
