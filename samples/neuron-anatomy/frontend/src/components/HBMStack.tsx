import React from 'react';
import { formatBytes } from '../lib/derive';

/**
 * One HBM stack drawn as a vertical block alongside a chip.
 *
 * Telemetry:
 *   - fill: chip.hbm_used_bytes / chip.hbm_total_bytes (driveable)
 *   - bandwidth animation: not exposed by neuron-monitor, so the stack
 *     stays static beyond the fill level.
 *
 * Trainium2 has 4 stacks per chip, drawn 2 above and 2 below by ChipDiagram.
 * This component renders one stack only.
 */
export interface HBMStackProps {
  ratio: number; // 0..1
  totalBytes: number;
  width: number;
  height: number;
  label?: string;
}

export const HBMStack: React.FC<HBMStackProps> = ({ ratio, totalBytes, width, height, label }) => {
  const r = Math.max(0, Math.min(1, ratio));
  const fillH = (height - 6) * r;
  return (
    <svg width={width} height={height} viewBox={`0 0 ${width} ${height}`}>
      <rect
        x={1}
        y={3}
        width={width - 2}
        height={height - 6}
        rx={3}
        fill="rgba(255,255,255,0.05)"
        stroke="rgba(120,180,255,0.4)"
        strokeWidth={0.8}
      />
      <rect
        x={1}
        y={3 + (height - 6) - fillH}
        width={width - 2}
        height={fillH}
        rx={3}
        fill="rgba(120,180,255,0.7)"
      />
      {/* HBM die boundaries (8 stacks visualised as static decoration) */}
      {Array.from({ length: 7 }).map((_, i) => (
        <line
          key={i}
          x1={1}
          x2={width - 1}
          y1={3 + ((height - 6) * (i + 1)) / 8}
          y2={3 + ((height - 6) * (i + 1)) / 8}
          stroke="rgba(255,255,255,0.08)"
          strokeWidth={0.5}
        />
      ))}
      {height > 60 && (
        <text x={width / 2} y={height - 1} fontSize={8} textAnchor="middle" fill="rgba(255,255,255,0.55)">
          {label ?? formatBytes(totalBytes)}
        </text>
      )}
    </svg>
  );
};
