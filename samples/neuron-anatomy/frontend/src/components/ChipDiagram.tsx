import React from 'react';
import type { ChipEngineSpecs, ChipSample, NeuronCoreSample, TopologyChip } from '../types';
import { hbmFillRatio } from '../lib/derive';
import { utilToColor } from '../lib/layout';
import { HBMStack } from './HBMStack';
import { NeuronCoreCell } from './NeuronCoreCell';

/**
 * Anatomy view for one chip: HBM stacks above and below, NeuronCore grid
 * in the middle.
 *
 * Instance-shape independence:
 *   - Per-chip core count comes from topology.nc_count (LNC=2 -> 4,
 *     LNC=1 -> 8, other SKUs may differ).
 *   - HBM stack count comes from engineSpecs.hbm_stack_count_per_chip
 *     (Trn2 = 4). If a future generation reports a different number, the
 *     layout splits the row above/below evenly.
 *   - No numeric chip/core constants are hard-coded.
 */
export interface ChipDiagramProps {
  chip: TopologyChip;
  sample: ChipSample | null;
  cores: NeuronCoreSample[];
  engineSpecs: ChipEngineSpecs;
  showV3dSplit: boolean;
  width: number;
  height: number;
  /** Compact rendering for the multi-chip overview grid. */
  compact?: boolean;
}

export const ChipDiagram: React.FC<ChipDiagramProps> = ({
  chip,
  sample,
  cores,
  engineSpecs,
  showV3dSplit,
  width,
  height,
  compact = false,
}) => {
  const hbmRatio = sample ? hbmFillRatio(sample) : 0;
  const stackCount = engineSpecs.hbm_stack_count_per_chip;
  // Split the HBM stacks: top row gets the ceiling (so odd counts look
  // balanced when bottom row is shorter).
  const topCount = Math.ceil(stackCount / 2);
  const bottomCount = stackCount - topCount;

  const hbmH = compact ? height * 0.16 : height * 0.13;
  const labelH = compact ? 0 : 18;
  const innerY = labelH + hbmH + 4;
  const innerH = height - innerY - hbmH - 4;

  const ncCount = chip.nc_count;
  // 4 cores -> 2x2; 8 cores -> 4x2; other counts -> ceil(sqrt) square.
  const cols = ncCount === 4 ? 2 : ncCount === 8 ? 4 : Math.ceil(Math.sqrt(ncCount));
  const rows = Math.ceil(ncCount / cols);
  const cellW = (width - 8 - (cols - 1) * 4) / cols;
  const cellH = (innerH - (rows - 1) * 4) / rows;

  const eccBadge =
    sample && (sample.ecc_corrected > 0 || sample.ecc_uncorrected > 0)
      ? sample.ecc_uncorrected > 0
        ? `ECC ${sample.ecc_uncorrected}!`
        : `ECC ${sample.ecc_corrected}`
      : null;

  return (
    <div
      style={{
        position: 'relative',
        width,
        height,
        background: `linear-gradient(180deg, rgba(20,28,40,0.88), rgba(12,18,28,0.88))`,
        border: `1px solid ${
          sample && sample.ecc_uncorrected > 0
            ? 'rgba(255,80,80,0.85)'
            : sample
            ? `rgba(${Math.round(120 + sample.avg_utilisation * 1.3)}, 200, 255, 0.5)`
            : 'rgba(255,255,255,0.15)'
        }`,
        borderRadius: 8,
        boxShadow: sample
          ? `0 0 ${4 + (sample.avg_utilisation / 100) * 18}px ${utilToColor(sample.avg_utilisation)}33`
          : 'none',
        boxSizing: 'border-box',
        padding: 4,
      }}
    >
      {!compact && (
        <div
          style={{
            position: 'absolute',
            top: 4,
            left: 8,
            right: 8,
            display: 'flex',
            justifyContent: 'space-between',
            color: 'rgba(255,255,255,0.7)',
            fontSize: 11,
            fontFamily: 'ui-monospace, monospace',
          }}
        >
          <span>
            chip {chip.neuron_device}
            {sample ? ` · ${sample.avg_utilisation.toFixed(0)}%` : ''}
          </span>
          <span>{eccBadge ?? engineSpecs.neuronlink_intra_label ?? ''}</span>
        </div>
      )}

      {/* HBM stacks above */}
      {topCount > 0 && (
        <div
          style={{
            position: 'absolute',
            top: labelH,
            left: 8,
            right: 8,
            height: hbmH,
            display: 'grid',
            gridTemplateColumns: `repeat(${topCount}, 1fr)`,
            gap: 4,
          }}
        >
          {Array.from({ length: topCount }).map((_, i) => (
            <HBMStack
              key={`top-${i}`}
              ratio={hbmRatio}
              totalBytes={chip.memory_size / stackCount}
              width={(width - 16 - (topCount - 1) * 4) / topCount}
              height={hbmH}
            />
          ))}
        </div>
      )}

      {/* NeuronCore grid */}
      <div
        style={{
          position: 'absolute',
          top: innerY,
          left: 4,
          right: 4,
          height: innerH,
          display: 'grid',
          gridTemplateColumns: `repeat(${cols}, 1fr)`,
          gridTemplateRows: `repeat(${rows}, 1fr)`,
          gap: 4,
        }}
      >
        {chip.neuroncore_ids.map((nc_id) => {
          const core = cores.find((c) => c.nc_id === nc_id) ?? null;
          return (
            <NeuronCoreCell
              key={nc_id}
              core={core}
              engineSpecs={engineSpecs}
              showV3dSplit={showV3dSplit}
              width={cellW}
              height={cellH}
            />
          );
        })}
      </div>

      {/* HBM stacks below */}
      {bottomCount > 0 && (
        <div
          style={{
            position: 'absolute',
            bottom: 4,
            left: 8,
            right: 8,
            height: hbmH,
            display: 'grid',
            gridTemplateColumns: `repeat(${bottomCount}, 1fr)`,
            gap: 4,
          }}
        >
          {Array.from({ length: bottomCount }).map((_, i) => (
            <HBMStack
              key={`bot-${i}`}
              ratio={hbmRatio}
              totalBytes={chip.memory_size / stackCount}
              width={(width - 16 - (bottomCount - 1) * 4) / bottomCount}
              height={hbmH}
            />
          ))}
        </div>
      )}
    </div>
  );
};
