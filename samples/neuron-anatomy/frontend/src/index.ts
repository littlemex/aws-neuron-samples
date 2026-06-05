// Public package entry. Only re-exports; the implementation lives in
// components/, hooks/, lib/, and types.ts.
export { NeuronDrawer } from './components/NeuronDrawer';
export type { NeuronDrawerProps } from './components/NeuronDrawer';
export { ChipGrid } from './components/ChipGrid';
export { ChipDiagram } from './components/ChipDiagram';
export { NeuronCoreCell } from './components/NeuronCoreCell';
export { HBMStack } from './components/HBMStack';
export { TopologyEdges } from './components/TopologyEdges';
export { useNeuronStream } from './hooks/useNeuronStream';
export { useNeuronTopology } from './hooks/useNeuronTopology';
export * from './types';
export { utilToColor, layoutChips, placeEdges } from './lib/layout';
export { buildCoreLookup, hbmFillRatio, sramFillRatio, formatBytes } from './lib/derive';
