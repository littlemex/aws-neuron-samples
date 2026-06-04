import type { ChipSample, NeuronCoreSample, Snapshot, TopologyResponse } from '../types';

/**
 * Frontend derive helpers.
 *
 * Backend (monitor.py) already aggregates per-chip averages, so the bulk
 * of the work here is "look up the cores that belong to this chip" plus
 * a couple of fill-ratio helpers used by the bars and HBM stacks.
 */

export interface CoreLookup {
  byChip: Map<number, NeuronCoreSample[]>;
  byNc: Map<number, NeuronCoreSample>;
}

export function buildCoreLookup(snapshot: Snapshot, topology: TopologyResponse): CoreLookup {
  const byNc = new Map<number, NeuronCoreSample>();
  for (const c of snapshot.cores) byNc.set(c.nc_id, c);

  const byChip = new Map<number, NeuronCoreSample[]>();
  for (const chip of topology.chips) {
    const cores: NeuronCoreSample[] = [];
    for (const ncId of chip.neuroncore_ids) {
      const c = byNc.get(ncId);
      if (c) cores.push(c);
    }
    byChip.set(chip.neuron_device, cores);
  }
  return { byChip, byNc };
}

export function chipById(snapshot: Snapshot): Map<number, ChipSample> {
  return new Map(snapshot.chips.map((c) => [c.neuron_device, c]));
}

/** HBM fill ratio in 0..1 (clamped). */
export function hbmFillRatio(chip: ChipSample): number {
  if (chip.hbm_total_bytes <= 0) return 0;
  return Math.max(0, Math.min(1, chip.hbm_used_bytes / chip.hbm_total_bytes));
}

/** SRAM fill ratio in 0..1 (clamped). Denominator comes from topology. */
export function sramFillRatio(core: NeuronCoreSample, sramPerCoreBytes: number): number {
  if (sramPerCoreBytes <= 0 || core.memory_used_bytes == null) return 0;
  return Math.max(0, Math.min(1, core.memory_used_bytes / sramPerCoreBytes));
}

/** Format a byte count as e.g. "12.3 GiB". */
export function formatBytes(bytes: number): string {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  let n = bytes;
  let i = 0;
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024;
    i += 1;
  }
  return `${n.toFixed(n >= 100 || i === 0 ? 0 : 1)} ${units[i]}`;
}
