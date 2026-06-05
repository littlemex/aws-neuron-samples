import React, { useEffect, useMemo, useState } from 'react';
import { useNeuronStream } from '../hooks/useNeuronStream';
import { useNeuronTopology } from '../hooks/useNeuronTopology';
import { buildCoreLookup, formatBytes } from '../lib/derive';
import { utilToColor } from '../lib/layout';
import { ChipDiagram } from './ChipDiagram';
import { ChipGrid } from './ChipGrid';
import { SystemStatsPanel } from './SystemStatsPanel';

/**
 * Top-level drawer to embed inside another sample (e.g. voice-image-edit).
 *
 * Collapsed state: a single header row showing aggregated utilisation.
 * Expanded state: ChipGrid on the left, plus a detailed ChipDiagram on
 * the right for the currently selected chip.
 *
 * On a single-chip instance (trn2.3xlarge) the right-hand pane is hidden
 * because the ChipGrid already shows the same chip at full size, and the
 * extra column would be a duplicate. Multi-chip instances always show
 * both panes so users can pick a chip from the overview and zoom in.
 *
 * The SSE subscription is only started when the drawer is open so the
 * backend stays idle while the host page is in its default state.
 */
export interface NeuronDrawerProps {
  /** Backend prefix. Use "/neuron" when going through CloudFront / ALB. */
  base?: string;
  /** Initial open state. Demos usually want true. */
  defaultOpen?: boolean;
  /** Collapsed-state height in px. */
  collapsedHeight?: number;
  /** Expanded-state height in px. */
  expandedHeight?: number;
}

export const NeuronDrawer: React.FC<NeuronDrawerProps> = ({
  base = '/neuron',
  defaultOpen = false,
  collapsedHeight = 36,
  expandedHeight = 320,
}) => {
  const [open, setOpen] = useState(defaultOpen);
  // Three-state size:
  //   'compact' = the historical fixed expandedHeight (kept as default so
  //               existing embedders are unaffected),
  //   'tall'    = ~70vh, large enough to read the chip silhouettes clearly,
  //   'full'    = ~95vh fullscreen-style overlay for demos and screenshots.
  const [size, setSize] = useState<'compact' | 'tall' | 'full'>('compact');
  const [vh, setVh] = useState<number>(() =>
    typeof window === 'undefined' ? 800 : window.innerHeight,
  );
  const [vw, setVw] = useState<number>(() =>
    typeof window === 'undefined' ? 1280 : window.innerWidth,
  );
  useEffect(() => {
    const onResize = () => {
      setVh(window.innerHeight);
      setVw(window.innerWidth);
    };
    window.addEventListener('resize', onResize);
    return () => window.removeEventListener('resize', onResize);
  }, []);
  const [selected, setSelected] = useState<number | null>(null);
  const { topology } = useNeuronTopology(base);
  const { snapshot, status } = useNeuronStream({ enabled: open, base });

  const headerStats = useMemo(() => computeHeaderStats(snapshot), [snapshot]);
  const selectedChip = useMemo(() => {
    if (!topology) return null;
    const id = selected ?? topology.chips[0]?.neuron_device ?? null;
    return topology.chips.find((c) => c.neuron_device === id) ?? null;
  }, [topology, selected]);
  const lookup = useMemo(
    () => (snapshot && topology ? buildCoreLookup(snapshot, topology) : null),
    [snapshot, topology],
  );

  const totalUtil = headerStats?.avgUtil ?? 0;
  const isSingleChip = (topology?.neuron_device_count ?? 0) <= 1;
  const effectiveExpanded =
    size === 'full' ? Math.round(vh * 0.95)
      : size === 'tall' ? Math.round(vh * 0.7)
      : expandedHeight;
  const innerHeight = effectiveExpanded - collapsedHeight - 24;
  const sysPanelWidth = Math.max(220, Math.min(320, Math.round(vw * 0.18)));

  return (
    <div
      style={{
        height: open ? effectiveExpanded : collapsedHeight,
        transition: 'height 220ms ease',
        background: 'linear-gradient(180deg, rgba(8,12,20,0.96), rgba(4,6,12,0.96))',
        borderTop: '1px solid rgba(255,255,255,0.1)',
        color: 'rgba(255,255,255,0.92)',
        fontFamily: 'ui-monospace, SFMono-Regular, monospace',
        boxSizing: 'border-box',
        overflow: 'hidden',
      }}
    >
      <button
        onClick={() => setOpen((v) => !v)}
        style={{
          height: collapsedHeight,
          width: '100%',
          background: 'transparent',
          border: 'none',
          color: 'inherit',
          padding: '0 12px',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'space-between',
          cursor: 'pointer',
          fontSize: 12,
        }}
      >
        <span style={{ display: 'flex', alignItems: 'center', gap: 8 }}>
          <span>{open ? '▼' : '▶'}</span>
          <span>Neuron Activity</span>
          {topology?.instance_type && (
            <span style={{ color: 'rgba(255,255,255,0.55)' }}>
              {topology.instance_type} · {topology.neuron_device_count}{' '}
              {topology.neuron_device_count === 1 ? 'chip' : 'chips'}
            </span>
          )}
        </span>
        <span style={{ display: 'flex', alignItems: 'center', gap: 12 }}>
          <UtilisationBadge value={totalUtil} />
          {headerStats && (
            <span style={{ color: 'rgba(255,255,255,0.7)' }}>
              HBM {formatBytes(headerStats.hbmUsed)} / {formatBytes(headerStats.hbmTotal)}
            </span>
          )}
          {headerStats?.eccCorrected ? (
            <span style={{ color: 'rgba(255,180,80,0.85)' }}>ECC {headerStats.eccCorrected}</span>
          ) : null}
          {headerStats?.eccUncorrected ? (
            <span style={{ color: 'rgba(255,80,80,0.85)' }}>ECC! {headerStats.eccUncorrected}</span>
          ) : null}
          <span style={{ color: 'rgba(255,255,255,0.4)' }}>{status}</span>
          {open && (
            <SizeToggle
              size={size}
              onChange={(s) => {
                setSize(s);
              }}
            />
          )}
        </span>
      </button>

      {open && topology && (
        <div
          style={{
            display: 'grid',
            // grid columns:
            //   single-chip: chip diagram + system stats
            //   multi-chip:  chip grid    + chip detail + system stats
            gridTemplateColumns: isSingleChip
              ? `minmax(0, 1fr) ${sysPanelWidth}px`
              : `minmax(0, 2fr) minmax(0, 1fr) ${sysPanelWidth}px`,
            gap: 12,
            padding: 12,
            height: effectiveExpanded - collapsedHeight,
            boxSizing: 'border-box',
          }}
        >
          <div style={{ position: 'relative', minWidth: 0 }}>
            <ChipGrid
              topology={topology}
              snapshot={snapshot}
              width={Math.max(400, gridWidthFor(topology, vw, size))}
              height={innerHeight}
              selectedChip={selected}
              onSelectChip={setSelected}
            />
          </div>
          {!isSingleChip && (
            <div style={{ minWidth: 0 }}>
              {selectedChip && (
                <ChipDiagram
                  chip={selectedChip}
                  sample={
                    snapshot?.chips.find(
                      (c) => c.neuron_device === selectedChip.neuron_device,
                    ) ?? null
                  }
                  cores={lookup?.byChip.get(selectedChip.neuron_device) ?? []}
                  engineSpecs={topology.chip_engine_specs}
                  showV3dSplit={(topology.logical_neuroncore_config ?? 1) >= 2}
                  width={Math.max(280, Math.min(420, Math.round(vw * 0.18)))}
                  height={innerHeight}
                />
              )}
            </div>
          )}
          <div style={{ minWidth: 0, overflow: 'auto' }}>
            <SystemStatsPanel
              system={snapshot?.system}
              width={sysPanelWidth}
              height={innerHeight}
              variant="global"
            />
          </div>
        </div>
      )}
    </div>
  );
};

function gridWidthFor(
  topology: { neuron_device_count: number },
  viewportWidth: number,
  size: 'compact' | 'tall' | 'full',
): number {
  // The grid used to be capped at 720/880 px regardless of how big the
  // viewport was, so on a 27" display the chips stayed tiny. Scale with
  // the viewport instead, but keep a sane lower bound for the original
  // compact embedding (so existing demos still render the same).
  const isFull = size === 'full';
  const isTall = size === 'tall';
  // Reserve roughly: (system stats ~280px) + (chip detail ~360px) + paddings.
  // Whatever's left is the grid width budget.
  const reserved = (isFull || isTall) ? 700 : 380;
  const budget = Math.max(400, viewportWidth - reserved);
  if (size === 'compact') {
    if (topology.neuron_device_count <= 16) return Math.min(budget, 720);
    return Math.min(budget, 880);
  }
  // tall / full: let the grid breathe up to ~70% of the viewport
  return Math.min(budget, Math.round(viewportWidth * 0.7));
}

const SizeToggle: React.FC<{
  size: 'compact' | 'tall' | 'full';
  onChange: (s: 'compact' | 'tall' | 'full') => void;
}> = ({ size, onChange }) => {
  const opts: Array<{ key: 'compact' | 'tall' | 'full'; label: string; title: string }> = [
    { key: 'compact', label: 'S', title: 'Compact (default)' },
    { key: 'tall', label: 'M', title: 'Tall (~70% viewport)' },
    { key: 'full', label: 'L', title: 'Fullscreen (~95% viewport)' },
  ];
  return (
    <span
      onClick={(e) => e.stopPropagation()}
      style={{
        display: 'inline-flex',
        alignItems: 'stretch',
        border: '1px solid rgba(255,255,255,0.15)',
        borderRadius: 6,
        overflow: 'hidden',
        height: 22,
      }}
    >
      {opts.map((o) => (
        <button
          key={o.key}
          title={o.title}
          onClick={(e) => {
            e.stopPropagation();
            onChange(o.key);
          }}
          style={{
            background: size === o.key ? 'rgba(98,212,128,0.22)' : 'transparent',
            color: size === o.key ? '#62d480' : 'rgba(255,255,255,0.7)',
            border: 'none',
            padding: '0 8px',
            fontSize: 11,
            fontWeight: 600,
            cursor: 'pointer',
            fontFamily: 'inherit',
          }}
        >
          {o.label}
        </button>
      ))}
    </span>
  );
};

function computeHeaderStats(snapshot: ReturnType<typeof useNeuronStream>['snapshot']): {
  avgUtil: number;
  hbmUsed: number;
  hbmTotal: number;
  eccCorrected: number;
  eccUncorrected: number;
} | null {
  if (!snapshot) return null;
  if (!snapshot.chips.length) return null;
  const avgUtil =
    snapshot.chips.reduce((acc, c) => acc + c.avg_utilisation, 0) / snapshot.chips.length;
  const hbmUsed = snapshot.chips.reduce((acc, c) => acc + c.hbm_used_bytes, 0);
  const hbmTotal = snapshot.chips.reduce((acc, c) => acc + c.hbm_total_bytes, 0);
  const eccCorrected = snapshot.chips.reduce((acc, c) => acc + c.ecc_corrected, 0);
  const eccUncorrected = snapshot.chips.reduce((acc, c) => acc + c.ecc_uncorrected, 0);
  return { avgUtil, hbmUsed, hbmTotal, eccCorrected, eccUncorrected };
}

const UtilisationBadge: React.FC<{ value: number }> = ({ value }) => (
  <span
    style={{
      background: utilToColor(value),
      color: 'rgba(0,0,0,0.85)',
      padding: '2px 8px',
      borderRadius: 999,
      fontVariantNumeric: 'tabular-nums',
      fontWeight: 600,
    }}
  >
    {value.toFixed(0)}%
  </span>
);
