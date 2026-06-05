import React from 'react';
import type { DeviceMemory, HostMemory, SystemStats, VcpuUsage } from '../types';
import { formatBytes } from '../lib/derive';

/**
 * Right-edge "system stats" rail. Mirrors the flavour of neuron-top's
 * vCPU / Memory Summary block but fed live from neuron-monitor.
 *
 * Two scopes:
 *   - "global"   : whole-host stats (used in NeuronDrawer next to ChipGrid)
 *   - "chip"     : same shape, slightly narrower for the per-chip detail
 *                  pane (ChipDiagram) so the layout still fits.
 *
 * Engine-level (TensorEngine / VectorEngine / GPSIMDEngine) breakdown is
 * not surfaced because neuron-monitor v2 does not publish per-engine
 * utilisation. The chip silhouettes already render the engines as labels.
 */

export interface SystemStatsPanelProps {
  system: SystemStats | null | undefined;
  /** Width budget. Heights flex. */
  width: number;
  /** Height budget. */
  height: number;
  /** Visual variant. "chip" trims labels for narrower layouts. */
  variant?: 'global' | 'chip';
}

export const SystemStatsPanel: React.FC<SystemStatsPanelProps> = ({
  system,
  width,
  height,
  variant = 'global',
}) => {
  const compact = variant === 'chip' || width < 220;
  return (
    <div
      style={{
        width,
        height,
        boxSizing: 'border-box',
        padding: compact ? '8px 8px' : '10px 12px',
        background: 'rgba(255,255,255,0.03)',
        border: '1px solid rgba(255,255,255,0.06)',
        borderRadius: 8,
        display: 'flex',
        flexDirection: 'column',
        gap: compact ? 8 : 12,
        overflow: 'hidden',
        fontVariantNumeric: 'tabular-nums',
      }}
      data-anatomy="system-stats"
    >
      <SectionTitle compact={compact}>vCPU Utilization</SectionTitle>
      <VcpuRow label="System"  vcpu={system?.system_vcpu  ?? null} compact={compact} />
      <VcpuRow label="Runtime" vcpu={system?.runtime_vcpu ?? null} compact={compact} />

      <SectionTitle compact={compact}>Host Memory</SectionTitle>
      <HostMemoryBlock host={system?.host_memory ?? null} compact={compact} />

      <SectionTitle compact={compact}>Device Memory</SectionTitle>
      <DeviceMemoryBlock device={system?.device_memory ?? null} compact={compact} />
    </div>
  );
};

const SectionTitle: React.FC<{ compact: boolean; children: React.ReactNode }> = ({
  compact,
  children,
}) => (
  <div
    style={{
      fontSize: compact ? 10 : 11,
      letterSpacing: '0.08em',
      textTransform: 'uppercase',
      color: 'rgba(255,255,255,0.55)',
      marginTop: 2,
    }}
  >
    {children}
  </div>
);

const VcpuRow: React.FC<{ label: string; vcpu: VcpuUsage | null; compact: boolean }> = ({
  label,
  vcpu,
  compact,
}) => {
  // Bar segments (left -> right): user, system, io_wait, irq+soft_irq.
  // Anything left over is idle and shown as the empty track.
  const user = vcpu?.user ?? 0;
  const system = vcpu?.system ?? 0;
  const ioWait = vcpu?.io_wait ?? 0;
  const irq = (vcpu?.irq ?? 0) + (vcpu?.soft_irq ?? 0);
  const busy = user + system + ioWait + irq;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
      <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: compact ? 10 : 11 }}>
        <span style={{ color: 'rgba(255,255,255,0.75)' }}>{label}</span>
        <span style={{ color: 'rgba(255,255,255,0.85)' }}>
          {vcpu ? `${busy.toFixed(2)}%` : '—'}
        </span>
      </div>
      <div
        title={
          vcpu
            ? `user ${user.toFixed(2)}%  system ${system.toFixed(2)}%  io_wait ${ioWait.toFixed(2)}%  irq+softirq ${irq.toFixed(2)}%`
            : 'no sample'
        }
        style={{
          position: 'relative',
          height: compact ? 6 : 8,
          background: 'rgba(255,255,255,0.06)',
          borderRadius: 4,
          overflow: 'hidden',
          display: 'flex',
        }}
      >
        <Seg pct={user}    color="#62d480" />
        <Seg pct={system}  color="#5aa8ff" />
        <Seg pct={ioWait}  color="#ffae57" />
        <Seg pct={irq}     color="#d784ff" />
      </div>
    </div>
  );
};

const Seg: React.FC<{ pct: number; color: string }> = ({ pct, color }) => {
  if (pct <= 0) return null;
  const w = Math.max(0, Math.min(100, pct));
  return <div style={{ width: `${w}%`, height: '100%', background: color }} />;
};

const HostMemoryBlock: React.FC<{ host: HostMemory | null; compact: boolean }> = ({
  host,
  compact,
}) => {
  if (!host) return <Empty compact={compact} />;
  const used = host.used_bytes;
  const total = host.total_bytes || 1;
  const usedPct = (used / total) * 100;
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
      <KeyVal compact={compact} k="Total" v={formatBytes(total)} />
      <KeyVal compact={compact} k="Used"  v={`${formatBytes(used)} (${usedPct.toFixed(1)}%)`} />
      <Bar compact={compact} value={usedPct} title={`${formatBytes(used)} / ${formatBytes(total)}`} />
      <Sub compact={compact} k="Tensors"      v={formatBytes(host.tensors_bytes)} />
      <Sub compact={compact} k="Constants"    v={formatBytes(host.constants_bytes)} />
      <Sub compact={compact} k="DMA Buffers"  v={formatBytes(host.dma_buffers_bytes)} />
      <Sub compact={compact} k="App. Memory"  v={formatBytes(host.application_memory_bytes)} />
    </div>
  );
};

const DeviceMemoryBlock: React.FC<{ device: DeviceMemory | null; compact: boolean }> = ({
  device,
  compact,
}) => {
  if (!device) return <Empty compact={compact} />;
  const total = device.total_bytes || 1;
  const used = device.used_bytes;
  const usedPct = (used / total) * 100;
  // Stacked bar of the live breakdown segments.
  const segs: { label: string; bytes: number; color: string }[] = [
    { label: 'Tensors',   bytes: device.tensors_bytes,                color: '#62d480' },
    { label: 'Constants', bytes: device.constants_bytes,              color: '#5aa8ff' },
    { label: 'Code',      bytes: device.model_code_bytes,             color: '#d784ff' },
    { label: 'Runtime',   bytes: device.runtime_memory_bytes,         color: '#ffae57' },
    { label: 'Scratch',   bytes: device.model_shared_scratchpad_bytes, color: '#ff7eb5' },
  ];
  return (
    <div style={{ display: 'flex', flexDirection: 'column', gap: 4 }}>
      <KeyVal compact={compact} k="Total" v={formatBytes(total)} />
      <KeyVal compact={compact} k="Used"  v={`${formatBytes(used)} (${usedPct.toFixed(1)}%)`} />
      <div
        style={{
          position: 'relative',
          height: compact ? 8 : 10,
          background: 'rgba(255,255,255,0.06)',
          borderRadius: 4,
          overflow: 'hidden',
          display: 'flex',
        }}
        title={segs.map((s) => `${s.label} ${formatBytes(s.bytes)}`).join('\n')}
      >
        {segs.map((s) => (
          <Seg key={s.label} pct={(s.bytes / total) * 100} color={s.color} />
        ))}
      </div>
      {segs.map((s) => (
        <Sub key={s.label} compact={compact} k={s.label} v={formatBytes(s.bytes)} dot={s.color} />
      ))}
    </div>
  );
};

const KeyVal: React.FC<{ k: string; v: string; compact: boolean }> = ({ k, v, compact }) => (
  <div style={{ display: 'flex', justifyContent: 'space-between', fontSize: compact ? 10 : 11 }}>
    <span style={{ color: 'rgba(255,255,255,0.6)' }}>{k}</span>
    <span style={{ color: 'rgba(255,255,255,0.92)' }}>{v}</span>
  </div>
);

const Sub: React.FC<{ k: string; v: string; compact: boolean; dot?: string }> = ({
  k,
  v,
  compact,
  dot,
}) => (
  <div
    style={{
      display: 'flex',
      justifyContent: 'space-between',
      alignItems: 'center',
      fontSize: compact ? 9 : 10,
      color: 'rgba(255,255,255,0.55)',
    }}
  >
    <span style={{ display: 'flex', alignItems: 'center', gap: 5 }}>
      {dot && (
        <span
          style={{
            display: 'inline-block',
            width: 6,
            height: 6,
            borderRadius: 999,
            background: dot,
          }}
        />
      )}
      {k}
    </span>
    <span style={{ color: 'rgba(255,255,255,0.78)' }}>{v}</span>
  </div>
);

const Bar: React.FC<{ value: number; compact: boolean; title?: string }> = ({
  value,
  compact,
  title,
}) => (
  <div
    title={title}
    style={{
      position: 'relative',
      height: compact ? 6 : 8,
      background: 'rgba(255,255,255,0.06)',
      borderRadius: 4,
      overflow: 'hidden',
    }}
  >
    <div
      style={{
        width: `${Math.min(100, Math.max(0, value))}%`,
        height: '100%',
        background: 'linear-gradient(90deg, #62d480, #5aa8ff)',
      }}
    />
  </div>
);

const Empty: React.FC<{ compact: boolean }> = ({ compact }) => (
  <div style={{ fontSize: compact ? 10 : 11, color: 'rgba(255,255,255,0.4)' }}>—</div>
);
