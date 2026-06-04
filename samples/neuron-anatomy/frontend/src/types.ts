/**
 * TypeScript mirror of the backend pydantic models in
 * neuron_anatomy/schemas.py. Keep field names in snake_case to match the
 * backend output verbatim. Three reasons:
 *   1) lets us drop in OpenAPI codegen later,
 *   2) keeps Python the single source of truth for naming,
 *   3) avoids confusion when other samples call the backend directly.
 */

export interface TopologyEdge {
  src: number;
  dst: number;
}

export interface TopologyChip {
  neuron_device: number;
  nc_count: number;
  neuroncore_ids: number[];
  memory_size: number;
  connected_to: number[];
}

export interface EngineSpec {
  name: string;
  role: string;
  peak_label: string | null;
  sub_lane_count: number | null;
}

export interface ChipEngineSpecs {
  chip_label: string;
  hbm_stack_count_per_chip: number;
  sram_per_neuroncore_bytes: number;
  neuronlink_intra_label: string | null;
  engines: EngineSpec[];
}

export interface TopologyResponse {
  instance_type: string | null;
  neuron_device_count: number;
  neuroncore_per_device_count: number;
  logical_neuroncore_config: number | null;
  chips: TopologyChip[];
  edges: TopologyEdge[];
  chip_engine_specs: ChipEngineSpecs;
}

export interface V3dSubCore {
  utilisation: number;
}

export interface NeuronCoreSample {
  nc_id: number;
  utilisation: number;
  flops: number | null;
  v3d_sub: V3dSubCore[] | null;
  memory_used_bytes: number | null;
}

export interface ChipSample {
  neuron_device: number;
  avg_utilisation: number;
  hbm_used_bytes: number;
  hbm_total_bytes: number;
  ecc_corrected: number;
  ecc_uncorrected: number;
}

export interface RuntimeSample {
  pid: number | null;
  tag: string | null;
  error_summary: Record<string, number>;
  latency_p50_ms: number | null;
  latency_p99_ms: number | null;
}

export interface Snapshot {
  ts_ms: number;
  available: boolean;
  chips: ChipSample[];
  cores: NeuronCoreSample[];
  runtimes: RuntimeSample[];
  raw: Record<string, unknown> | null;
}

export interface NeuronAnatomyEndpoints {
  /** Path that GET /neuron/topology lives under. Default "/neuron". */
  base?: string;
}
