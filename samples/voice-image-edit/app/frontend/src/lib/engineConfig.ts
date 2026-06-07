/**
 * Persists the per-slot engine selection (ASR / VLM / EDIT / GENERATE / TTS)
 * in localStorage so the user's choice survives reloads and tab switches.
 *
 * Design:
 *   - A single localStorage key (`vie.engineConfig`) holds a JSON object
 *     keyed by slot name.
 *   - Missing or corrupt values fall back to the backend's /engines default.
 *   - Cross-tab updates propagate via the native storage event; same-tab
 *     listeners get a custom event because storage doesn't fire in the
 *     originating tab.
 *   - At request time, read via getEngineConfig() and attach
 *     `body.engine = config[slot]` to the outgoing request body.
 */
'use client';

import { useCallback, useEffect, useMemo, useState } from 'react';
import {
  fetchSlotsCatalog,
  type SlotName,
  type SlotsCatalog,
} from './api';

const STORAGE_KEY = 'vie.engineConfig';
const STORAGE_EVENT = 'vie:engineConfig';

export type EngineConfig = Partial<Record<SlotName, string>>;

function readStorage(): EngineConfig {
  if (typeof window === 'undefined') return {};
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw) as unknown;
    if (parsed && typeof parsed === 'object') {
      const obj = parsed as EngineConfig;
      // Only accept slots whose stored value is a non-empty string.
      const out: EngineConfig = {};
      (['asr', 'vlm', 'edit', 'generate', 'tts'] as SlotName[]).forEach((slot) => {
        const v = obj[slot];
        if (typeof v === 'string' && v.length > 0) out[slot] = v;
      });
      return out;
    }
  } catch {
    /* ignore */
  }
  return {};
}

function writeStorage(cfg: EngineConfig) {
  if (typeof window === 'undefined') return;
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(cfg));
  // Dispatch a custom event so listeners in the same tab are notified;
  // the native storage event only fires in other tabs, so we need both.
  window.dispatchEvent(new CustomEvent(STORAGE_EVENT));
}

export function getEngineConfig(): EngineConfig {
  return readStorage();
}

export function setEngineForSlot(slot: SlotName, engine: string | undefined) {
  const cur = readStorage();
  if (!engine) {
    delete cur[slot];
  } else {
    cur[slot] = engine;
  }
  writeStorage(cur);
}

export function clearEngineConfig() {
  writeStorage({});
}

/**
 * React hook that returns the current engine config alongside the backend's
 * engine catalog.
 * - The catalog is fetched once on mount (no-store).
 * - localStorage changes are synced via the storage event and a same-tab
 *   custom event.
 */
export function useEngineConfig() {
  const [catalog, setCatalog] = useState<SlotsCatalog | null>(null);
  const [config, setConfig] = useState<EngineConfig>(() => readStorage());
  const [catalogError, setCatalogError] = useState<string | null>(null);
  const [catalogLoading, setCatalogLoading] = useState(true);

  useEffect(() => {
    let active = true;
    setCatalogLoading(true);
    fetchSlotsCatalog()
      .then((c) => {
        if (!active) return;
        if (!c) {
          setCatalogError('engines API が応答しませんでした');
        } else {
          setCatalog(c);
        }
      })
      .finally(() => {
        if (active) setCatalogLoading(false);
      });
    return () => {
      active = false;
    };
  }, []);

  useEffect(() => {
    const sync = () => setConfig(readStorage());
    window.addEventListener('storage', sync);
    window.addEventListener(STORAGE_EVENT, sync);
    return () => {
      window.removeEventListener('storage', sync);
      window.removeEventListener(STORAGE_EVENT, sync);
    };
  }, []);

  const setSlot = useCallback((slot: SlotName, engine: string | undefined) => {
    setEngineForSlot(slot, engine);
    setConfig(readStorage());
  }, []);

  /**
   * Returns the resolved engine name to attach to outgoing requests.
   * 1) If localStorage has a value, use it.
   * 2) Otherwise use the backend default from the catalog if present.
   * 3) Otherwise undefined (defer to the API's DEFAULT_FALLBACK).
   */
  const resolved: Record<SlotName, string | undefined> = useMemo(() => {
    const out: Record<SlotName, string | undefined> = {
      asr: undefined,
      vlm: undefined,
      edit: undefined,
      generate: undefined,
      tts: undefined,
    };
    (['asr', 'vlm', 'edit', 'generate', 'tts'] as SlotName[]).forEach((slot) => {
      out[slot] = config[slot] ?? catalog?.[slot]?.default;
    });
    return out;
  }, [config, catalog]);

  return {
    catalog,
    catalogError,
    catalogLoading,
    config,
    resolved,
    setSlot,
    clear: () => {
      clearEngineConfig();
      setConfig({});
    },
  };
}
