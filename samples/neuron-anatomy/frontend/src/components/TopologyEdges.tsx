import React from 'react';
import type { PlacedEdge } from '../lib/layout';

/**
 * SVG layer drawn over the chip grid to render NeuronLink adjacencies.
 *
 * No live telemetry is available for NeuronLink, so edges stay static.
 * Intra-cluster edges are solid; cluster-spanning edges (UltraServer
 * inter-node ring) use a dashed stroke to distinguish them.
 *
 * On trn2.3xlarge there are no edges, so this component renders an
 * empty SVG layer with no children -- safe and free.
 */
export interface TopologyEdgesProps {
  edges: PlacedEdge[];
  width: number;
  height: number;
}

export const TopologyEdges: React.FC<TopologyEdgesProps> = ({ edges, width, height }) => (
  <svg
    width={width}
    height={height}
    viewBox={`0 0 ${width} ${height}`}
    style={{ position: 'absolute', inset: 0, pointerEvents: 'none' }}
  >
    {edges.map((e, i) => (
      <line
        key={i}
        x1={e.x1 * width}
        y1={e.y1 * height}
        x2={e.x2 * width}
        y2={e.y2 * height}
        stroke={e.intraCluster ? 'rgba(120,180,255,0.35)' : 'rgba(255,180,120,0.45)'}
        strokeWidth={e.intraCluster ? 1.4 : 1.0}
        strokeDasharray={e.intraCluster ? undefined : '4 3'}
      />
    ))}
  </svg>
);
