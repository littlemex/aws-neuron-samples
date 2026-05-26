'use client';

import Link from 'next/link';
import { useEffect, useRef, useState } from 'react';
import { ImageDropzone } from '@/components/ImageDropzone';
import { VoiceRecorder } from '@/components/VoiceRecorder';
import {
  streamPipeline,
  type EditResponseBody,
  type EngineMetadata,
  type StreamPipelineEvent,
  type VlmResponseBody,
} from '@/lib/api';
import { useEngineConfig } from '@/lib/engineConfig';

type StageId = 'asr' | 'vlm_instruction' | 'edit' | 'vlm_review';
type StageStatus = 'pending' | 'running' | 'done' | 'error' | 'skipped';

interface StageState {
  status: StageStatus;
  detail?: string;
  error?: string;
}

const STAGE_LABEL: Record<StageId, string> = {
  asr: '音声→テキスト',
  vlm_instruction: '指示生成',
  edit: '画像編集',
  vlm_review: '講評',
};

const STAGE_ORDER: StageId[] = ['asr', 'vlm_instruction', 'edit', 'vlm_review'];

function initialStages(): Record<StageId, StageState> {
  return {
    asr: { status: 'pending' },
    vlm_instruction: { status: 'pending' },
    edit: { status: 'pending' },
    vlm_review: { status: 'pending' },
  };
}

type StageCompletePayload = {
  stage: StageId;
  engine?: string;
  text?: string;
  image_url?: string;
  image_format?: string;
  image_bytes?: number;
  metadata?: Partial<EngineMetadata>;
};

type StageErrorPayload = {
  stage: StageId | 'config';
  code?: string;
  message?: string;
};

export default function EditPage() {
  const { resolved } = useEngineConfig();
  const [imageB64, setImageB64] = useState<string | null>(null);
  const [imageDataUrl, setImageDataUrl] = useState<string | null>(null);
  const [userInstruction, setUserInstruction] = useState('');
  const [editPrompt, setEditPrompt] = useState('');
  const [editResult, setEditResult] = useState<EditResponseBody | null>(null);
  const [reviewResult, setReviewResult] = useState<VlmResponseBody | null>(null);
  const [stages, setStages] = useState<Record<StageId, StageState>>(initialStages());
  const [running, setRunning] = useState(false);
  const [globalError, setGlobalError] = useState<string | null>(null);
  const abortRef = useRef<AbortController | null>(null);

  const updateStage = (id: StageId, patch: Partial<StageState>) =>
    setStages((s) => ({ ...s, [id]: { ...s[id], ...patch } }));

  // E2E test bridge: Playwright cannot reliably trigger React's onChange
  // for hidden file inputs in headless Chromium. The hook is a no-op in
  // normal browser usage. Removing it would re-introduce the file-input
  // flake we hit during P9-D.
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const w = window as unknown as Record<string, unknown>;
    w.__e2eSetImage = (b64: string, dataUrl: string) => {
      setImageB64(b64);
      setImageDataUrl(dataUrl);
    };
    w.__e2eSetInstruction = (text: string) => {
      setUserInstruction(text);
    };
    return () => {
      delete w.__e2eSetImage;
      delete w.__e2eSetInstruction;
    };
  }, []);

  const reset = () => {
    setStages(initialStages());
    setEditPrompt('');
    setEditResult(null);
    setReviewResult(null);
    setGlobalError(null);
  };

  const formatLatency = (md?: Partial<EngineMetadata>): string => {
    if (!md) return '';
    const parts: string[] = [];
    if (md.model_id) parts.push(md.model_id);
    if (typeof md.latency_ms === 'number') parts.push(`${md.latency_ms}ms`);
    return parts.join(' / ');
  };

  const runPipeline = async () => {
    if (!imageB64) {
      setGlobalError('画像を選択してください');
      return;
    }
    if (!userInstruction.trim()) {
      setGlobalError('編集指示が空です');
      return;
    }
    reset();
    setRunning(true);

    // ASR stage は VoiceRecorder で確定済みなので skipped 扱い。
    updateStage('asr', { status: 'skipped', detail: '入力済' });

    abortRef.current = new AbortController();
    try {
      const events = streamPipeline(
        {
          image_b64: imageB64,
          user_instruction: userInstruction,
          vlm_engine: resolved.vlm,
          edit_engine: resolved.edit,
        },
        abortRef.current.signal,
      );

      for await (const evt of events) {
        handleSseEvent(evt);
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      setGlobalError(msg);
      setStages((s) => {
        const next = { ...s };
        for (const id of STAGE_ORDER) {
          if (next[id].status === 'running') {
            next[id] = { ...next[id], status: 'error', error: msg };
          }
        }
        return next;
      });
    } finally {
      setRunning(false);
      abortRef.current = null;
    }
  };

  const handleSseEvent = (evt: StreamPipelineEvent) => {
    switch (evt.event) {
      case 'pipeline_start':
        return;
      case 'stage_start': {
        const stage = (evt.data as { stage?: StageId }).stage;
        if (stage) updateStage(stage, { status: 'running' });
        return;
      }
      case 'stage_complete': {
        const p = evt.data as StageCompletePayload;
        if (!p.stage) return;
        if (p.stage === 'vlm_instruction') {
          const text = p.text ?? '';
          setEditPrompt(text);
          updateStage('vlm_instruction', {
            status: 'done',
            detail: formatLatency(p.metadata),
          });
        } else if (p.stage === 'edit') {
          const result: EditResponseBody = {
            engine: p.engine ?? 'unknown',
            image_url: p.image_url ?? '',
            image_format: p.image_format ?? 'png',
            image_bytes: p.image_bytes,
            metadata: {
              model_id: p.metadata?.model_id ?? p.engine ?? 'unknown',
              latency_ms: p.metadata?.latency_ms ?? 0,
              request_id: p.metadata?.request_id,
              extra: (p.metadata?.extra ?? {}) as Record<string, unknown>,
            },
          };
          setEditResult(result);
          updateStage('edit', {
            status: 'done',
            detail: formatLatency(p.metadata),
          });
        } else if (p.stage === 'vlm_review') {
          const result: VlmResponseBody = {
            engine: p.engine ?? 'unknown',
            text: p.text ?? '',
            metadata: {
              model_id: p.metadata?.model_id ?? p.engine ?? 'unknown',
              latency_ms: p.metadata?.latency_ms ?? 0,
              request_id: p.metadata?.request_id,
              extra: (p.metadata?.extra ?? {}) as Record<string, unknown>,
            },
          };
          setReviewResult(result);
          updateStage('vlm_review', {
            status: 'done',
            detail: formatLatency(p.metadata),
          });
        }
        return;
      }
      case 'stage_error': {
        const p = evt.data as StageErrorPayload;
        const msg = `${p.code ?? 'error'}: ${p.message ?? 'unknown error'}`;
        if (p.stage === 'config') {
          setGlobalError(msg);
          return;
        }
        if (p.stage) updateStage(p.stage as StageId, { status: 'error', error: msg });
        return;
      }
      case 'pipeline_complete':
        return;
    }
  };

  return (
    // 画面ぴったりに収める。body スクロール禁止。
    <main className="flex h-screen w-screen flex-col overflow-hidden bg-[#0d1117] p-4 text-gray-100">
      {/* 上部ヘッダ: タイトル + engine + /manage */}
      <header className="mb-3 flex items-center justify-between">
        <h1 className="text-lg font-semibold tracking-wide">音声で画像を編集</h1>
        <div className="flex items-center gap-3 text-[11px] text-gray-400">
          <span>
            ASR <code className="text-gray-200">{resolved.asr ?? 'default'}</code>
          </span>
          <span>
            VLM <code className="text-gray-200">{resolved.vlm ?? 'default'}</code>
          </span>
          <span>
            EDIT <code className="text-gray-200">{resolved.edit ?? 'default'}</code>
          </span>
          <Link href="/manage" className="text-blue-400 hover:underline">
            /manage
          </Link>
        </div>
      </header>

      {/* メイン: 2 カラム。grid-rows-[1fr_auto] で残り高さを画像に渡す */}
      <div className="grid min-h-0 flex-1 grid-cols-1 gap-4 md:grid-cols-2">
        {/* ===== LEFT: BEFORE + 入力 ===== */}
        <section className="grid min-h-0 grid-rows-[1fr_auto] gap-3">
          <ImageDropzone
            onPick={(b64, dataUrl) => {
              setImageB64(b64);
              setImageDataUrl(dataUrl);
              reset();
            }}
          />
          <div className="space-y-2">
            <VoiceRecorder onTranscript={(t) => setUserInstruction(t)} />
            <textarea
              value={userInstruction}
              onChange={(e) => setUserInstruction(e.target.value)}
              placeholder="例: 赤いドレスに変更して"
              className="h-16 w-full resize-none rounded-lg border border-gray-700 bg-gray-900/60 p-2 text-sm text-white placeholder:text-gray-600 focus:border-blue-500 focus:outline-none"
            />
            <button
              onClick={() => runPipeline().catch(() => undefined)}
              disabled={running || !imageB64 || !userInstruction.trim()}
              data-testid="run-pipeline"
              className="w-full rounded-lg bg-emerald-600 px-4 py-2 text-sm font-medium text-white shadow transition hover:bg-emerald-500 disabled:cursor-not-allowed disabled:bg-gray-700 disabled:text-gray-400"
            >
              {running ? '実行中…' : '画像を編集する'}
            </button>
            {globalError && (
              <div className="truncate rounded border border-red-700 bg-red-950 px-2 py-1 text-xs text-red-300">
                {globalError}
              </div>
            )}
          </div>
        </section>

        {/* ===== RIGHT: AFTER + パイプライン進捗 + レビュー ===== */}
        <section className="grid min-h-0 grid-rows-[1fr_auto_auto] gap-3">
          <AfterPanel
            after={editResult}
            loading={stages.edit.status === 'running'}
            beforeAvailable={Boolean(imageDataUrl)}
          />
          <PipelineSteps stages={stages} />
          <ReviewPanel review={reviewResult} editPrompt={editPrompt} />
        </section>
      </div>
    </main>
  );
}

function AfterPanel({
  after,
  loading,
  beforeAvailable,
}: {
  after: EditResponseBody | null;
  loading: boolean;
  beforeAvailable: boolean;
}) {
  return (
    <div className="relative flex min-h-0 items-center justify-center overflow-hidden rounded-lg border border-gray-700 bg-black/40">
      {loading ? (
        <div className="flex flex-col items-center gap-2 text-gray-400">
          <span className="h-6 w-6 animate-spin rounded-full border-2 border-gray-600 border-t-blue-400" />
          <span className="text-xs">画像を編集中…</span>
        </div>
      ) : after ? (
        <>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={after.image_url}
            alt="after"
            className="max-h-full max-w-full object-contain"
          />
          <div className="pointer-events-none absolute bottom-2 left-2 right-2 truncate rounded bg-black/70 px-2 py-1 text-[11px] text-gray-200">
            {after.metadata.model_id} · {after.metadata.latency_ms}ms
          </div>
        </>
      ) : (
        <div className="text-center text-sm text-gray-500">
          {beforeAvailable
            ? '右に編集後の画像が表示されます'
            : '左に画像を選択してください'}
        </div>
      )}
    </div>
  );
}

function PipelineSteps({
  stages,
}: {
  stages: Record<StageId, StageState>;
}) {
  return (
    <ol
      className="flex items-center justify-between gap-2 rounded-lg border border-gray-800 bg-gray-950/60 px-3 py-2"
      data-testid="pipeline-stages"
    >
      {STAGE_ORDER.map((id, i) => {
        const s = stages[id].status;
        const tone =
          s === 'running'
            ? 'border-blue-500 bg-blue-950 text-blue-200'
            : s === 'done'
            ? 'border-emerald-600 bg-emerald-950 text-emerald-200'
            : s === 'error'
            ? 'border-red-600 bg-red-950 text-red-200'
            : s === 'skipped'
            ? 'border-gray-700 bg-gray-900 text-gray-500'
            : 'border-gray-700 bg-gray-900 text-gray-500';
        return (
          <li
            key={id}
            className="flex flex-1 items-center"
            data-testid={`stage-${id}`}
          >
            <div
              className={`flex w-full flex-col items-center rounded-md border px-2 py-1 transition ${tone}`}
            >
              <div className="flex items-center gap-1.5 text-[11px] uppercase">
                <span
                  className={`inline-flex h-4 w-4 items-center justify-center rounded-full text-[10px] ${
                    s === 'running'
                      ? 'bg-blue-500 text-white'
                      : s === 'done'
                      ? 'bg-emerald-500 text-white'
                      : s === 'error'
                      ? 'bg-red-500 text-white'
                      : 'bg-gray-700 text-gray-300'
                  }`}
                >
                  {s === 'running' ? '…' : s === 'done' ? '✓' : s === 'error' ? '!' : i + 1}
                </span>
                <span className="text-xs text-gray-200">{STAGE_LABEL[id]}</span>
              </div>
              {stages[id].detail && (
                <div className="mt-0.5 truncate text-[10px] text-gray-400">
                  {stages[id].detail}
                </div>
              )}
            </div>
            {i < STAGE_ORDER.length - 1 && (
              <div className="mx-1 h-px w-3 flex-shrink-0 bg-gray-700" />
            )}
          </li>
        );
      })}
    </ol>
  );
}

function ReviewPanel({
  review,
  editPrompt,
}: {
  review: VlmResponseBody | null;
  editPrompt: string;
}) {
  if (!review && !editPrompt) {
    return (
      <div className="rounded-lg border border-gray-800 bg-gray-950/60 px-3 py-2 text-xs text-gray-600">
        編集プロンプト・講評はここに出ます
      </div>
    );
  }
  return (
    <div className="flex max-h-32 flex-col gap-2 overflow-auto rounded-lg border border-gray-800 bg-gray-950/60 px-3 py-2 text-xs">
      {editPrompt && (
        <div>
          <div className="text-[10px] uppercase tracking-wider text-gray-500">
            編集プロンプト
          </div>
          <div className="mt-0.5 whitespace-pre-wrap text-gray-200">{editPrompt}</div>
        </div>
      )}
      {review && (
        <div>
          <div className="text-[10px] uppercase tracking-wider text-gray-500">
            講評 ({review.metadata.model_id})
          </div>
          <div className="mt-0.5 whitespace-pre-wrap text-gray-200">{review.text}</div>
        </div>
      )}
    </div>
  );
}
