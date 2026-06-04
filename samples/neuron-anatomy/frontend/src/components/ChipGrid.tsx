import React, { useMemo } from 'react';
import type { Snapshot, TopologyResponse } from '../types';
import { buildCoreLookup, chipById } from '../lib/derive';
import { layoutChips, placeEdges } from '../lib/layout';
import { ChipDiagram } from './ChipDiagram';
import { TopologyEdges } from './TopologyEdges';

/**
 * Multi-chip overview: lays out one compact ChipDiagram per chip and
 * overlays NeuronLink edges from connected_to[].
 *
 * For trn2.3xlarge there is exactly one chip and zero edges. Rather than
 * drawing a tiny tile in the centre, the single-chip case fills the
 * available area and skips the inset margin so the user sees a real
 * full-resolution anatomy view rather than a postage stamp.
 */
export interface ChipGridProps {
  topology: TopologyResponse;
  snapshot: Snapshot | null;
  width: number;
  height: number;
  selectedChip: number | null;
  onSelectChip: (neuron_device: number) => void;
}

export const ChipGrid: React.FC<ChipGridProps> = ({
  topology,
  snapshot,
  width,
  height,
  selectedChip,
  onSelectChip,
}) => {
  const layout = useMemo(() => layoutChips(topology.chips), [topology.chips]);
  const placedEdges = useMemo(
    () => placeEdges(layout, topology.edges),
    [layout, topology.edges],
  );
  const chipMap = useMemo(() => (snapshot ? chipById(snapshot) : new Map()), [snapshot]);
  const lookup = useMemo(
    () => (snapshot && topology ? buildCoreLookup(snapshot, topology) : null),
    [snapshot, topology],
  );

  const showV3dSplit = (topology.logical_neuroncore_config ?? 1) >= 2;
  const n = layout.chips.length;
  const isSingleChip = n === 1;

  // Per-cell footprint. For 1 chip we fill the whole panel; otherwise we
  // size by the grid produced by layoutChips.
  const cellW = isSingleChip ? width : width / Math.ceil(Math.sqrt(n));
  const cellH = isSingleChip ? height : height / Math.ceil(Math.sqrt(n));
  const compactW = isSingleChip ? width - 16 : Math.min(cellW * 0.85, 220);
  const compactH = isSingleChip ? height - 16 : Math.min(cellH * 0.85, 220);

  return (
    <div style={{ position: 'relative', width, height }}>
      <TopologyEdges edges={placedEdges} width={width} height={height} />
      {layout.chips.map((p) => {
        const topoChip = topology.chips.find((c) => c.neuron_device === p.neuron_device);
        if (!topoChip) return null;
        const sample = chipMap.get(p.neuron_device) ?? null;
        const cores = lookup?.byChip.get(p.neuron_device) ?? [];
        const isSelected = selectedChip === p.neuron_device;
        return (
          <button
            key={p.neuron_device}
            onClick={() => onSelectChip(p.neuron_device)}
            style={{
              position: 'absolute',
              left: p.x * width - compactW / 2,
              top: p.y * height - compactH / 2,
              width: compactW,
              height: compactH,
              padding: 0,
              background: 'transparent',
              border: isSelected ? '2px solid rgba(255,255,255,0.85)' : '1px solid transparent',
              borderRadius: 10,
              cursor: 'pointer',
              transition: 'transform 120ms ease',
              transform: isSelected ? 'scale(1.04)' : 'scale(1)',
            }}
            aria-label={`Chip ${p.neuron_device}`}
          >
            <ChipDiagram
              chip={topoChip}
              sample={sample}
              cores={cores}
              engineSpecs={topology.chip_engine_specs}
              showV3dSplit={showV3dSplit}
              width={compactW}
              height={compactH}
              compact={!isSingleChip}
            />
          </button>
        );
      })}
    </div>
  );
};
