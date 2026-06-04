import type { TopologyChip, TopologyEdge } from '../types';

/**
 * Translate a chip count into a 2-D placement.
 *
 * Instance-shape independent:
 *   - 1 chip          -> single centre placement (trn2.3xlarge)
 *   - 16 chips        -> 4x4 grid (trn2.48xlarge / trn2u.48xlarge)
 *   - 64 chips        -> 4 clusters of 4x4 grid (Trn2 UltraServer)
 *   - other counts    -> ceil(sqrt(n)) square fallback
 *
 * No SKU is hard-coded: the chip count is the only switch, and edges are
 * drawn from connected_to[] verbatim.
 */
export interface ChipPlacement {
  neuron_device: number;
  /** Normalised position in [0, 1] x [0, 1]. Works for SVG and CSS. */
  x: number;
  y: number;
  /** Cluster index (0..3 for UltraServer; 0 otherwise). */
  cluster: number;
}

export interface Layout {
  width: number;
  height: number;
  chips: ChipPlacement[];
  /** Bounding rectangles per cluster, used to draw an UltraServer node frame. */
  clusterRects: { cluster: number; x: number; y: number; w: number; h: number }[];
}

export function layoutChips(chips: TopologyChip[]): Layout {
  const n = chips.length;
  if (n === 0) return { width: 1, height: 1, chips: [], clusterRects: [] };
  if (n === 1) {
    return {
      width: 1,
      height: 1,
      chips: [{ neuron_device: chips[0].neuron_device, x: 0.5, y: 0.5, cluster: 0 }],
      clusterRects: [{ cluster: 0, x: 0, y: 0, w: 1, h: 1 }],
    };
  }
  if (n === 16) return gridLayout(chips, 4, 4, 0);
  if (n === 64) return ultraServerLayout(chips);

  const side = Math.ceil(Math.sqrt(n));
  return gridLayout(chips, side, Math.ceil(n / side), 0);
}

function gridLayout(chips: TopologyChip[], cols: number, rows: number, cluster: number): Layout {
  const placements: ChipPlacement[] = chips.map((c, i) => {
    const row = Math.floor(i / cols);
    const col = i % cols;
    return {
      neuron_device: c.neuron_device,
      x: (col + 0.5) / cols,
      y: (row + 0.5) / rows,
      cluster,
    };
  });
  return {
    width: 1,
    height: 1,
    chips: placements,
    clusterRects: [{ cluster, x: 0, y: 0, w: 1, h: 1 }],
  };
}

function ultraServerLayout(chips: TopologyChip[]): Layout {
  // 4 nodes x 16 chips. chips is assumed sorted by neuron_device, so we
  // pull blocks of 16 in order.
  const placements: ChipPlacement[] = [];
  const clusterRects: Layout['clusterRects'] = [];
  for (let cluster = 0; cluster < 4; cluster++) {
    const ox = (cluster % 2) * 0.5;
    const oy = Math.floor(cluster / 2) * 0.5;
    clusterRects.push({ cluster, x: ox, y: oy, w: 0.5, h: 0.5 });
    for (let i = 0; i < 16; i++) {
      const c = chips[cluster * 16 + i];
      if (!c) continue;
      const row = Math.floor(i / 4);
      const col = i % 4;
      placements.push({
        neuron_device: c.neuron_device,
        x: ox + ((col + 0.5) / 4) * 0.5,
        y: oy + ((row + 0.5) / 4) * 0.5,
        cluster,
      });
    }
  }
  return { width: 1, height: 1, chips: placements, clusterRects };
}

export interface PlacedEdge extends TopologyEdge {
  x1: number;
  y1: number;
  x2: number;
  y2: number;
  /** True for edges within one cluster; false for inter-node ring edges. */
  intraCluster: boolean;
}

export function placeEdges(layout: Layout, edges: TopologyEdge[]): PlacedEdge[] {
  const byId = new Map(layout.chips.map((c) => [c.neuron_device, c]));
  const out: PlacedEdge[] = [];
  for (const e of edges) {
    const a = byId.get(e.src);
    const b = byId.get(e.dst);
    if (!a || !b) continue;
    out.push({
      ...e,
      x1: a.x,
      y1: a.y,
      x2: b.x,
      y2: b.y,
      intraCluster: a.cluster === b.cluster,
    });
  }
  return out;
}

/**
 * Map neuroncore_utilization (0..100) to an HSL string compatible with
 * Tailwind colour tokens. 0 -> cool blue, 50 -> amber, 100 -> magenta.
 */
export function utilToColor(util: number): string {
  const u = Math.max(0, Math.min(100, util));
  // Hue interpolated as 220 (blue) -> 35 (amber) -> 320 (magenta).
  const hue = u < 50 ? 220 - (220 - 35) * (u / 50) : 35 - (35 - 320) * ((u - 50) / 50);
  const sat = 70 + (u / 100) * 30;
  const light = 35 + (u / 100) * 25;
  return `hsl(${Math.round(hue)} ${Math.round(sat)}% ${Math.round(light)}%)`;
}
