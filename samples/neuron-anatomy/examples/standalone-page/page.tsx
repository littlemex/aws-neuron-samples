/**
 * Standalone Next.js page (App Router) that mounts neuron-anatomy on its
 * own. Drop this file into any Next.js project at e.g.
 * src/app/neuron/page.tsx and visit /neuron.
 *
 * `base` is the prefix used by the backend. Going through CloudFront /
 * ALB you keep "/neuron". For local dev against a backend on :8810 you
 * can either rewrite "/neuron/*" in next.config.js or pass an absolute
 * URL such as base="http://localhost:8810/neuron".
 */
'use client';

import React from 'react';
import { NeuronDrawer } from '@aws-neuron-samples/neuron-anatomy';

export default function NeuronAnatomyStandalone() {
  return (
    <main
      style={{
        height: '100vh',
        display: 'flex',
        flexDirection: 'column',
        background: 'rgb(8,10,16)',
        color: 'rgba(255,255,255,0.9)',
        fontFamily: 'ui-sans-serif, system-ui, sans-serif',
      }}
    >
      <header style={{ padding: '20px 24px' }}>
        <h1 style={{ margin: 0, fontSize: 18 }}>Neuron Anatomy — live demo</h1>
        <p style={{ margin: '8px 0 0', color: 'rgba(255,255,255,0.55)', fontSize: 13 }}>
          Minimal page that consumes the neuron-anatomy backend. With the
          backend running this page shows the live Trainium chip anatomy.
        </p>
      </header>
      <div style={{ flex: 1 }} />
      <NeuronDrawer base="/neuron" defaultOpen expandedHeight={420} />
    </main>
  );
}
