import { useEffect, useRef, useState } from 'react';
import type { Snapshot } from '../types';

/**
 * Subscribe to GET /neuron/stream (SSE) and track the latest Snapshot.
 *
 * Uses the browser EventSource API (no POST body needed). EventSource
 * reconnects automatically on transport errors, so ALB target deregister
 * or CloudFront idle close are absorbed silently.
 *
 * When `enabled` flips to false the connection is torn down immediately,
 * so a collapsed drawer in voice-image-edit stops the stream and avoids
 * extra load on neuron-monitor.
 */
export function useNeuronStream(opts: {
  enabled: boolean;
  base?: string;
}): {
  snapshot: Snapshot | null;
  status: 'connecting' | 'open' | 'closed' | 'error';
} {
  const { enabled, base = '/neuron' } = opts;
  const [snapshot, setSnapshot] = useState<Snapshot | null>(null);
  const [status, setStatus] = useState<'connecting' | 'open' | 'closed' | 'error'>('closed');
  const esRef = useRef<EventSource | null>(null);

  useEffect(() => {
    if (!enabled) {
      esRef.current?.close();
      esRef.current = null;
      setStatus('closed');
      return;
    }

    setStatus('connecting');
    const es = new EventSource(`${base}/stream`, { withCredentials: true });
    esRef.current = es;

    es.addEventListener('open', () => setStatus('open'));
    es.addEventListener('error', () => setStatus('error'));
    es.addEventListener('snapshot', (ev) => {
      try {
        const data = JSON.parse((ev as MessageEvent).data) as Snapshot;
        setSnapshot(data);
      } catch {
        // Ignore malformed frames
      }
    });

    return () => {
      es.close();
      esRef.current = null;
      setStatus('closed');
    };
  }, [enabled, base]);

  return { snapshot, status };
}
