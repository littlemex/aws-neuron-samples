import { useEffect, useState } from 'react';
import type { TopologyResponse } from '../types';

/**
 * Fetch GET /neuron/topology once at mount and keep the result in state.
 *
 * Topology is static for the life of the dashboard, so we do not refetch
 * on every render. On error the component just receives null + the error
 * object, and the caller can fall back to a placeholder rather than
 * blowing up the page.
 */
export function useNeuronTopology(base = '/neuron'): {
  topology: TopologyResponse | null;
  error: Error | null;
  reload: () => void;
} {
  const [topology, setTopology] = useState<TopologyResponse | null>(null);
  const [error, setError] = useState<Error | null>(null);
  const [tick, setTick] = useState(0);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const res = await fetch(`${base}/topology`, { credentials: 'include' });
        if (!res.ok) throw new Error(`topology ${res.status}`);
        const json = (await res.json()) as TopologyResponse;
        if (!cancelled) {
          setTopology(json);
          setError(null);
        }
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e : new Error(String(e)));
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [base, tick]);

  return { topology, error, reload: () => setTick((t) => t + 1) };
}
