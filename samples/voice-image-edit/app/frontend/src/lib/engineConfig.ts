/**
 * 3 スロット (ASR / VLM / EDIT) のエンジン選択を localStorage で永続化する。
 *
 * 設計:
 *   - localStorage の単一 key (`vie.engineConfig`) に
 *     `{asr, vlm, edit}` 3 フィールドだけを JSON で保存する。
 *   - 値が無い / 壊れている時は backend の /engines 既定値にフォールバック。
 *   - ページ間で値が変わったら storage event で他タブにも伝搬させる。
 *   - リクエスト送信時は getEngineConfig() で読み込み、
 *     `body.engine = config[slot]` を載せて送る。
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
      // 値が文字列の slot だけ採用
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
  // 同一タブ内の他リスナにも届かせるため CustomEvent を併用
  // (storage event は別タブにしか飛ばないので両方用意する)
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
 * 設定 + backend の候補一覧を併せて返す React hook。
 * - 候補一覧はマウント時に 1 回だけ取得 (no-store)。
 * - localStorage 変更は storage / 同一タブの custom event で同期する。
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
   * リクエスト送信時の解決済みエンジン名を返す。
   * 1) localStorage に値がある → それを使う
   * 2) backend の default が catalog にあればそれ
   * 3) 何も無ければ undefined (Lambda 側の DEFAULT_FALLBACK に委ねる)
   */
  const resolved: Record<SlotName, string | undefined> = useMemo(() => {
    const out: Record<SlotName, string | undefined> = {
      asr: undefined,
      vlm: undefined,
      edit: undefined,
      generate: undefined,
      tts: undefined,
    };
    (['asr', 'vlm', 'edit'] as SlotName[]).forEach((slot) => {
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
