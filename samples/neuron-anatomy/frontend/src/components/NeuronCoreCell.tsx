import React from 'react';
import type { ChipEngineSpecs, EngineSpec, NeuronCoreSample } from '../types';
import { sramFillRatio, formatBytes } from '../lib/derive';
import { utilToColor } from '../lib/layout';

/**
 * Anatomy cell for a single NeuronCore.
 *
 * Internal layout (faithful to NeuronCore-v3 docs):
 *   - TensorEngine (large): occupies the upper half. Static silhouette
 *     because neuron-monitor does not expose per-engine utilisation.
 *   - VectorEngine + ScalarEngine: middle row, side by side. Static.
 *   - GPSIMDEngine: bottom row drawn as 8 sub-lanes. Static.
 *   - SRAM bar: very bottom; the only fill that is actually driveable.
 *   - Outer frame fill: tinted by neuroncore_utilization.
 *   - Under LNC=2 we overlay two thin vertical bars on the right with the
 *     v3d.0 / v3d.1 sub-utilisation values.
 */
export interface NeuronCoreCellProps {
  core: NeuronCoreSample | null;
  engineSpecs: ChipEngineSpecs;
  showV3dSplit: boolean;
  width: number;
  height: number;
}

export const NeuronCoreCell: React.FC<NeuronCoreCellProps> = ({
  core,
  engineSpecs,
  showV3dSplit,
  width,
  height,
}) => {
  const util = core?.utilisation ?? 0;
  const fill = utilToColor(util);
  const sramRatio = core ? sramFillRatio(core, engineSpecs.sram_per_neuroncore_bytes) : 0;

  // Vertical layout (relative): tensor 0..0.45, vector+scalar 0.45..0.63,
  // gpsimd 0.63..0.81, sram 0.81..1.0.
  const tensorH = height * 0.45;
  const midY = tensorH;
  const midH = height * 0.18;
  const gpsimdY = midY + midH;
  const gpsimdH = height * 0.18;
  const sramY = gpsimdY + gpsimdH;
  const sramH = height - sramY;

  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`}>
      {/* Outer frame, tinted by utilisation */}
      <rect
        x={0}
        y={0}
        width={width}
        height={height}
        rx={4}
        fill={fill}
        opacity={0.18 + 0.42 * (util / 100)}
        stroke="rgba(255,255,255,0.18)"
        strokeWidth={1}
      />

      {/* TensorEngine */}
      <EngineSilhouette
        x={4}
        y={4}
        w={width - 8}
        h={tensorH - 8}
        label="Tensor"
        spec={engineSpecs.engines.find((e) => e.name === 'TensorEngine') ?? null}
      />

      {/* Vector + Scalar (side by side) */}
      <EngineSilhouette
        x={4}
        y={midY}
        w={(width - 12) / 2}
        h={midH - 4}
        label="Vector"
        spec={engineSpecs.engines.find((e) => e.name === 'VectorEngine') ?? null}
      />
      <EngineSilhouette
        x={4 + (width - 12) / 2 + 4}
        y={midY}
        w={(width - 12) / 2}
        h={midH - 4}
        label="Scalar"
        spec={engineSpecs.engines.find((e) => e.name === 'ScalarEngine') ?? null}
      />

      {/* GPSIMD: 8 sub-lanes drawn as static rectangles */}
      <GpsimdSilhouette
        x={4}
        y={gpsimdY}
        w={width - 8}
        h={gpsimdH - 4}
        spec={engineSpecs.engines.find((e) => e.name === 'GPSIMDEngine') ?? null}
      />

      {/* SRAM bar (driveable from neuroncore_memory_usage) */}
      <g>
        <rect x={4} y={sramY} width={width - 8} height={sramH - 4} rx={2} fill="rgba(255,255,255,0.06)" />
        <rect
          x={4}
          y={sramY}
          width={(width - 8) * sramRatio}
          height={sramH - 4}
          rx={2}
          fill="rgba(140,200,255,0.85)"
        />
        <text
          x={width / 2}
          y={sramY + (sramH - 4) / 2 + 3}
          fontSize={Math.max(8, Math.min(11, height / 11))}
          textAnchor="middle"
          fill="rgba(255,255,255,0.9)"
        >
          SRAM {core?.memory_used_bytes != null ? formatBytes(core.memory_used_bytes) : '—'}
        </text>
      </g>

      {/* LNC=2 sub-cell bars */}
      {showV3dSplit && core?.v3d_sub && core.v3d_sub.length === 2 && (
        <g>
          <rect
            x={width - 7}
            y={4}
            width={3}
            height={(height - 8) * (core.v3d_sub[0].utilisation / 100)}
            fill={utilToColor(core.v3d_sub[0].utilisation)}
          />
          <rect
            x={width - 3}
            y={4}
            width={3}
            height={(height - 8) * (core.v3d_sub[1].utilisation / 100)}
            fill={utilToColor(core.v3d_sub[1].utilisation)}
          />
        </g>
      )}

      {/* Utilisation label */}
      <text
        x={width - 6}
        y={14}
        fontSize={Math.max(9, Math.min(12, height / 10))}
        textAnchor="end"
        fill="rgba(255,255,255,0.95)"
        style={{ fontVariantNumeric: 'tabular-nums' }}
      >
        {util.toFixed(0)}%
      </text>
    </svg>
  );
};

const EngineSilhouette: React.FC<{
  x: number;
  y: number;
  w: number;
  h: number;
  label: string;
  spec: EngineSpec | null;
}> = ({ x, y, w, h, label, spec }) => (
  <g>
    <rect
      x={x}
      y={y}
      width={w}
      height={h}
      rx={3}
      fill="rgba(255,255,255,0.04)"
      stroke="rgba(255,255,255,0.22)"
      strokeWidth={0.6}
    />
    <text
      x={x + 4}
      y={y + 11}
      fontSize={9}
      fill="rgba(255,255,255,0.6)"
      style={{ letterSpacing: 0.5 }}
    >
      {label}
    </text>
    {spec?.peak_label && h > 24 && (
      <text x={x + 4} y={y + h - 4} fontSize={8} fill="rgba(255,255,255,0.4)">
        {spec.peak_label}
      </text>
    )}
  </g>
);

const GpsimdSilhouette: React.FC<{
  x: number;
  y: number;
  w: number;
  h: number;
  spec: EngineSpec | null;
}> = ({ x, y, w, h, spec }) => {
  const lanes = spec?.sub_lane_count ?? 8;
  const laneW = (w - 8) / lanes;
  return (
    <g>
      <rect
        x={x}
        y={y}
        width={w}
        height={h}
        rx={3}
        fill="rgba(255,255,255,0.04)"
        stroke="rgba(255,255,255,0.22)"
        strokeWidth={0.6}
      />
      {Array.from({ length: lanes }).map((_, i) => (
        <rect
          key={i}
          x={x + 4 + laneW * i + 1}
          y={y + 4}
          width={laneW - 2}
          height={h - 8}
          fill="rgba(255,255,255,0.08)"
        />
      ))}
      <text x={x + 4} y={y + 11} fontSize={9} fill="rgba(255,255,255,0.6)">
        GPSIMD ×{lanes}
      </text>
    </g>
  );
};
