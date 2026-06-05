'use client';

import Link from 'next/link';
import { useEffect, useMemo, useRef, useState } from 'react';
import { ImageDropzone } from '@/components/ImageDropzone';
import { VoiceRecorder } from '@/components/VoiceRecorder';
import {
  fetchImageAsBase64,
  streamGeneratePipeline,
  streamPipeline,
  type EditResponseBody,
  type EngineMetadata,
  type StreamPipelineEvent,
  type VlmResponseBody,
} from '@/lib/api';
import { useEngineConfig } from '@/lib/engineConfig';
import { NeuronDrawer } from '@aws-neuron-samples/neuron-anatomy';

// edit pipeline:    ASR -> VLM(instruction) -> EDIT -> VLM(review) -> [TTS]
// generate pipeline: ASR -> VLM(translate, optional) -> GENERATE
// Both reuse the same component so StageId is a union over both shapes.
type StageId =
  | 'asr'
  | 'vlm_instruction'
  | 'edit'
  | 'vlm_review'
  | 'vlm_translate'
  | 'generate'
  | 'tts';
type StageStatus = 'pending' | 'running' | 'done' | 'error' | 'skipped';

interface StageState {
  status: StageStatus;
  detail?: string;
  error?: string;
}

type Mode = 'edit' | 'generate';

const STAGE_LABEL: Record<StageId, string> = {
  asr: '音声→テキスト',
  vlm_instruction: '指示生成',
  edit: '画像編集',
  vlm_review: '講評',
  vlm_translate: 'プロンプト整形',
  generate: '画像生成',
  tts: '読み上げ',
};

const STAGE_ORDER_EDIT_BASE: StageId[] = ['asr', 'vlm_instruction', 'edit', 'vlm_review'];
const STAGE_ORDER_GENERATE: StageId[] = ['asr', 'vlm_translate', 'generate'];
const STAGE_ORDER_FOR_MODE = (mode: Mode, enableTts: boolean): StageId[] => {
  if (mode === 'generate') return STAGE_ORDER_GENERATE;
  return enableTts ? [...STAGE_ORDER_EDIT_BASE, 'tts'] : STAGE_ORDER_EDIT_BASE;
};

function initialStages(): Record<StageId, StageState> {
  return {
    asr: { status: 'pending' },
    vlm_instruction: { status: 'pending' },
    edit: { status: 'pending' },
    vlm_review: { status: 'pending' },
    vlm_translate: { status: 'pending' },
    generate: { status: 'pending' },
    tts: { status: 'pending' },
  };
}

const ENABLE_TTS_KEY = 'vie.enableTts.v1';

// localStorage key for the most recent generated image. We persist a single
// slot only — the user's request was "the latest generated image, available
// for the next edit run" — so a stack/queue would be over-engineered.
const LAST_GENERATED_KEY = 'vie.lastGeneratedImage.v1';

interface LastGeneratedImage {
  /** base64 PNG, no data: prefix */
  image_b64: string;
  /** data: URL form for direct <img src> rendering */
  image_data_url: string;
  /** Original (or translated) prompt that produced it. */
  prompt: string;
  /** ms epoch when it was saved. */
  saved_at_ms: number;
}

async function downloadImage(imageUrl: string, mode: Mode): Promise<void> {
  try {
    const res = await fetch(imageUrl, { cache: 'no-store' });
    if (!res.ok) throw new Error(`http_${res.status}`);
    const blob = await res.blob();
    const objectUrl = URL.createObjectURL(blob);
    const a = document.createElement('a');
    const ts = new Date()
      .toISOString()
      .replace(/[:.]/g, '-')
      .replace('T', '_')
      .slice(0, 19);
    a.href = objectUrl;
    a.download = `voice-image-${mode}-${ts}.png`;
    document.body.appendChild(a);
    a.click();
    a.remove();
    setTimeout(() => URL.revokeObjectURL(objectUrl), 5_000);
  } catch (err) {
    // Surface a minimal alert; the demo box has no toast component.
    // The image is still visible via the <img> tag, so the user can
    // also right-click → save image as a fallback path.
    // eslint-disable-next-line no-alert
    alert(`画像の保存に失敗しました: ${err instanceof Error ? err.message : err}`);
  }
}

async function cacheGeneratedImage(
  imageUrl: string,
  prompt: string,
): Promise<LastGeneratedImage | null> {
  try {
    const b64 = await fetchImageAsBase64(imageUrl);
    const dataUrl = `data:image/png;base64,${b64}`;
    const value: LastGeneratedImage = {
      image_b64: b64,
      image_data_url: dataUrl,
      prompt,
      saved_at_ms: Date.now(),
    };
    writeLastGenerated(value);
    return value;
  } catch {
    return null;
  }
}

function readLastGenerated(): LastGeneratedImage | null {
  if (typeof window === 'undefined') return null;
  try {
    const raw = window.localStorage.getItem(LAST_GENERATED_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as LastGeneratedImage;
    if (!parsed?.image_b64 || !parsed?.image_data_url) return null;
    return parsed;
  } catch {
    return null;
  }
}

function writeLastGenerated(value: LastGeneratedImage) {
  if (typeof window === 'undefined') return;
  try {
    window.localStorage.setItem(LAST_GENERATED_KEY, JSON.stringify(value));
  } catch {
    /* quota / private mode — silently drop, the in-memory copy still works */
  }
}

type StageCompletePayload = {
  stage: StageId;
  engine?: string;
  text?: string;
  image_url?: string;
  image_format?: string;
  image_bytes?: number;
  audio_url?: string;
  audio_format?: string;
  audio_bytes?: number;
  metadata?: Partial<EngineMetadata>;
};

type StageErrorPayload = {
  stage: StageId | 'config';
  code?: string;
  message?: string;
};

export default function EditPage() {
  const { resolved } = useEngineConfig();
  const [mode, setMode] = useState<Mode>('edit');
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
  // Cache of the most recent successfully generated image. Lives in
  // localStorage so a refresh / page nav keeps it; in-memory state is the
  // source of truth during a session.
  const [lastGenerated, setLastGenerated] = useState<LastGeneratedImage | null>(
    null,
  );
  useEffect(() => {
    setLastGenerated(readLastGenerated());
  }, []);
  // Whether to run the TTS stage that reads the review aloud after edit.
  // Persisted in localStorage so the toggle survives reloads.
  const [enableTts, setEnableTts] = useState(false);
  useEffect(() => {
    if (typeof window === 'undefined') return;
    const v = window.localStorage.getItem(ENABLE_TTS_KEY);
    if (v === '1') setEnableTts(true);
  }, []);
  useEffect(() => {
    if (typeof window === 'undefined') return;
    window.localStorage.setItem(ENABLE_TTS_KEY, enableTts ? '1' : '0');
  }, [enableTts]);
  // Latest TTS result (audio_url + format). Auto-played when present.
  const [ttsResult, setTtsResult] = useState<{
    audio_url: string;
    audio_format: string;
    engine: string;
  } | null>(null);

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
    setTtsResult(null);
    setGlobalError(null);
  };

  const formatLatency = (md?: Partial<EngineMetadata>): string => {
    if (!md) return '';
    const parts: string[] = [];
    if (md.model_id) parts.push(md.model_id);
    if (typeof md.latency_ms === 'number') parts.push(`${md.latency_ms}ms`);
    return parts.join(' / ');
  };

  const runEditPipeline = async () => {
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
          enable_tts: enableTts,
          tts_engine: resolved.tts,
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
        for (const id of STAGE_ORDER_EDIT_BASE) {
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

  const runGeneratePipeline = async () => {
    if (!userInstruction.trim()) {
      setGlobalError('生成プロンプトが空です');
      return;
    }
    reset();
    setRunning(true);

    updateStage('asr', { status: 'skipped', detail: '入力済' });

    abortRef.current = new AbortController();
    try {
      const events = streamGeneratePipeline(
        {
          user_instruction: userInstruction,
          // The translate stage uses the same engine slot as the edit
          // pipeline's instruction/review steps, so the operator picks
          // VLM once on /manage and it applies to all VLM-backed stages.
          vlm_engine: resolved.vlm,
          generate_engine: resolved.generate,
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
        for (const id of STAGE_ORDER_GENERATE) {
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

  const runPipeline = () =>
    mode === 'generate' ? runGeneratePipeline() : runEditPipeline();

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
        } else if (p.stage === 'edit' || p.stage === 'generate') {
          // edit and generate share the same wire shape (image_url + metadata)
          // so the rendering path is unified; only the stage id differs for
          // progress display. When a generate succeeds we also fetch the
          // image and stash it for the next edit run.
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
          updateStage(p.stage, {
            status: 'done',
            detail: formatLatency(p.metadata),
          });
          if (p.stage === 'generate' && result.image_url) {
            // Fire-and-forget: cache the result for re-use in edit mode.
            // Errors here are non-fatal (the image is already shown via
            // <img src={image_url} />), so we just log and move on.
            void cacheGeneratedImage(result.image_url, userInstruction).then(
              (saved) => {
                if (saved) setLastGenerated(saved);
              },
            );
          }
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
        } else if (p.stage === 'tts' && p.audio_url) {
          setTtsResult({
            audio_url: p.audio_url,
            audio_format: p.audio_format ?? 'mp3',
            engine: p.engine ?? 'unknown',
          });
          updateStage('tts', {
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
      {/* Top header: title + mode toggle + engine names + /manage link */}
      <header className="mb-3 flex items-center justify-between">
        <div className="flex items-center gap-3">
          <h1 className="text-lg font-semibold tracking-wide">
            音声で画像を{mode === 'generate' ? '生成' : '編集'}
          </h1>
          <div
            className="inline-flex items-stretch overflow-hidden rounded-md border border-gray-700"
            data-testid="mode-toggle"
          >
            <button
              type="button"
              data-testid="mode-edit"
              onClick={() => {
                setMode('edit');
                reset();
              }}
              disabled={running}
              className={`px-3 py-1 text-xs font-medium ${
                mode === 'edit'
                  ? 'bg-emerald-600 text-white'
                  : 'bg-transparent text-gray-300 hover:bg-gray-800'
              } disabled:cursor-not-allowed disabled:opacity-50`}
            >
              編集
            </button>
            <button
              type="button"
              data-testid="mode-generate"
              onClick={() => {
                setMode('generate');
                reset();
              }}
              disabled={running}
              className={`border-l border-gray-700 px-3 py-1 text-xs font-medium ${
                mode === 'generate'
                  ? 'bg-violet-600 text-white'
                  : 'bg-transparent text-gray-300 hover:bg-gray-800'
              } disabled:cursor-not-allowed disabled:opacity-50`}
            >
              生成
            </button>
          </div>
          {mode === 'edit' && (
            <button
              type="button"
              data-testid="tts-toggle"
              onClick={() => setEnableTts((v) => !v)}
              disabled={running}
              title="講評を音声で読み上げる"
              className={`flex items-center gap-1 rounded-md border px-2 py-1 text-[11px] font-medium transition disabled:cursor-not-allowed disabled:opacity-50 ${
                enableTts
                  ? 'border-amber-500 bg-amber-600 text-white hover:bg-amber-500'
                  : 'border-gray-700 bg-transparent text-gray-300 hover:bg-gray-800'
              }`}
            >
              <span>{enableTts ? '🔊' : '🔇'}</span>
              <span>講評を読み上げ</span>
            </button>
          )}
        </div>
        <div className="flex items-center gap-3 text-[11px] text-gray-400">
          <span>
            ASR <code className="text-gray-200">{resolved.asr ?? 'default'}</code>
          </span>
          {mode === 'edit' ? (
            <>
              <span>
                VLM <code className="text-gray-200">{resolved.vlm ?? 'default'}</code>
              </span>
              <span>
                EDIT <code className="text-gray-200">{resolved.edit ?? 'default'}</code>
              </span>
              {enableTts && (
                <span>
                  TTS <code className="text-gray-200">{resolved.tts ?? 'default'}</code>
                </span>
              )}
            </>
          ) : (
            <span>
              GEN <code className="text-gray-200">{resolved.generate ?? 'default'}</code>
            </span>
          )}
          <Link href="/manage" className="text-blue-400 hover:underline">
            /manage
          </Link>
        </div>
      </header>

      {/* Main area: 2 columns; grid-rows-[1fr_auto] gives remaining height
          to the image. min-h-0 + overflow-hidden are required because the
          ImageDropzone otherwise grows to its intrinsic content size on
          upload and pushes the NeuronDrawer (rendered as a sibling below)
          off-screen, which made uploaded images overlap the drawer. */}
      <div className="grid min-h-0 flex-1 grid-cols-1 gap-4 overflow-hidden md:grid-cols-2">
        {/* ===== LEFT column: BEFORE image + voice/text input =====
            In generate mode the input image is unused, so we dim the
            Dropzone and disable pointer events instead of removing the
            component (removing it shifts the layout). The "reuse last
            generated" button sits ABOVE the Dropzone — placing it below
            stacked it on top of the voice recorder and made it
            unreachable. */}
        <section className="grid min-h-0 grid-rows-[auto_1fr_auto] gap-2">
          {mode === 'edit' && lastGenerated ? (
            <button
              type="button"
              onClick={() => {
                setImageB64(lastGenerated.image_b64);
                setImageDataUrl(lastGenerated.image_data_url);
                reset();
              }}
              disabled={running}
              data-testid="reuse-last-generated"
              className="flex w-full items-center justify-center gap-2 truncate rounded-md border border-violet-700 bg-violet-950/40 px-2 py-1 text-[11px] text-violet-200 hover:bg-violet-900/60 disabled:cursor-not-allowed disabled:opacity-40"
              title={lastGenerated.prompt}
            >
              <span>↻ 直近の生成画像を使う</span>
              <span className="text-[10px] text-violet-400">
                ({new Date(lastGenerated.saved_at_ms).toLocaleTimeString()})
              </span>
            </button>
          ) : (
            <div className="h-0" />
          )}
          <div
            className={`min-h-0 ${
              mode === 'generate' ? 'pointer-events-none opacity-30' : ''
            }`}
            aria-hidden={mode === 'generate'}
          >
            <ImageDropzone
              onPick={(b64, dataUrl) => {
                setImageB64(b64);
                setImageDataUrl(dataUrl);
                reset();
              }}
            />
          </div>
          <div className="space-y-2">
            <VoiceRecorder onTranscript={(t) => setUserInstruction(t)} />
            <textarea
              value={userInstruction}
              onChange={(e) => setUserInstruction(e.target.value)}
              placeholder={
                mode === 'generate'
                  ? '例: 桜が咲く京都の路地、夕暮れ、フォトリアリスティック'
                  : '例: 赤いドレスに変更して'
              }
              className="h-16 w-full resize-none rounded-lg border border-gray-700 bg-gray-900/60 p-2 text-sm text-white placeholder:text-gray-600 focus:border-blue-500 focus:outline-none"
            />
            <button
              onClick={() => runPipeline().catch(() => undefined)}
              disabled={
                running ||
                !userInstruction.trim() ||
                (mode === 'edit' && !imageB64)
              }
              data-testid="run-pipeline"
              className={`w-full rounded-lg px-4 py-2 text-sm font-medium text-white shadow transition disabled:cursor-not-allowed disabled:bg-gray-700 disabled:text-gray-400 ${
                mode === 'generate'
                  ? 'bg-violet-600 hover:bg-violet-500'
                  : 'bg-emerald-600 hover:bg-emerald-500'
              }`}
            >
              {running
                ? '実行中…'
                : mode === 'generate'
                ? '画像を生成する'
                : '画像を編集する'}
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
            loading={
              mode === 'generate'
                ? stages.generate.status === 'running'
                : stages.edit.status === 'running'
            }
            beforeAvailable={mode === 'generate' || Boolean(imageDataUrl)}
            mode={mode}
          />
          <PipelineSteps stages={stages} order={STAGE_ORDER_FOR_MODE(mode, enableTts)} />
          {mode === 'edit' && (
            <ReviewPanel review={reviewResult} editPrompt={editPrompt} tts={ttsResult} />
          )}
        </section>
      </div>
      {/* The drawer is the last child of <main>. Pin it to the flex tail,
          cancel out the parent's padding so it reaches the viewport edge,
          and use flex-shrink-0 so the grid above cannot steal height from
          it (which is what caused image-upload overlap previously). */}
      <div className="-mx-4 -mb-4 mt-2 flex-shrink-0">
        <NeuronDrawer base="/neuron" defaultOpen />
      </div>
    </main>
  );
}

function AfterPanel({
  after,
  loading,
  beforeAvailable,
  mode,
}: {
  after: EditResponseBody | null;
  loading: boolean;
  beforeAvailable: boolean;
  mode: Mode;
}) {
  const loadingLabel = mode === 'generate' ? '画像を生成中…' : '画像を編集中…';
  const idleLabel =
    mode === 'generate'
      ? '右に生成された画像が表示されます'
      : beforeAvailable
      ? '右に編集後の画像が表示されます'
      : '左に画像を選択してください';
  return (
    <div className="relative flex min-h-0 items-center justify-center overflow-hidden rounded-lg border border-gray-700 bg-black/40">
      {loading ? (
        <div className="flex flex-col items-center gap-2 text-gray-400">
          <span className="h-6 w-6 animate-spin rounded-full border-2 border-gray-600 border-t-blue-400" />
          <span className="text-xs">{loadingLabel}</span>
        </div>
      ) : after ? (
        <>
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={after.image_url}
            alt={mode === 'generate' ? 'generated' : 'after'}
            className="max-h-full max-w-full object-contain"
          />
          <div className="pointer-events-none absolute bottom-2 left-2 right-2 truncate rounded bg-black/70 px-2 py-1 text-[11px] text-gray-200">
            {after.metadata.model_id} · {after.metadata.latency_ms}ms
          </div>
          <button
            type="button"
            onClick={() => downloadImage(after.image_url, mode)}
            data-testid="download-image"
            title="画像を保存"
            className="absolute right-2 top-2 rounded-md border border-gray-600 bg-gray-900/85 px-2 py-1 text-[11px] text-gray-100 shadow hover:bg-gray-800"
          >
            ⤓ 保存
          </button>
        </>
      ) : (
        <div className="text-center text-sm text-gray-500">{idleLabel}</div>
      )}
    </div>
  );
}

function PipelineSteps({
  stages,
  order,
}: {
  stages: Record<StageId, StageState>;
  order: StageId[];
}) {
  // Stages were previously laid out with `flex-1`, which forced narrow
  // labels (Japanese characters wrapped one-per-line on small viewports
  // and "vlm_review" was clipped off the right edge). Switch to
  // horizontal scroll with fixed-width tiles and auto-scroll the most
  // recent active stage into the centre so the user always sees the
  // current step regardless of pipeline length.
  const scrollerRef = useRef<HTMLOListElement | null>(null);
  const itemRefs = useRef<Record<StageId, HTMLLIElement | null>>(
    {} as Record<StageId, HTMLLIElement | null>,
  );

  // Pick the most "interesting" stage to centre — running > error > done.
  // Falls back to the last stage in order so the rightmost item is still
  // reachable when nothing is active yet.
  const focusId = useMemo<StageId>(() => {
    const priority: StageStatus[] = ['running', 'error', 'done', 'skipped'];
    for (const status of priority) {
      const found = [...order].reverse().find((id) => stages[id].status === status);
      if (found) return found;
    }
    return order[order.length - 1];
  }, [stages, order]);

  useEffect(() => {
    const el = itemRefs.current[focusId];
    const scroller = scrollerRef.current;
    if (!el || !scroller) return;
    // scrollIntoView with `inline: 'center'` honours the horizontally
    // scrolling parent without yanking the page scroll on small screens.
    el.scrollIntoView({ behavior: 'smooth', inline: 'center', block: 'nearest' });
  }, [focusId]);

  return (
    <ol
      ref={scrollerRef}
      className="scrollbar-thin flex snap-x snap-mandatory items-stretch gap-3 overflow-x-auto rounded-lg border border-gray-800 bg-gray-950/60 px-3 py-2"
      data-testid="pipeline-stages"
    >
      {order.map((id, i) => {
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
            ref={(el) => {
              itemRefs.current[id] = el;
            }}
            className="flex shrink-0 snap-center items-center"
            data-testid={`stage-${id}`}
          >
            <div
              className={`flex min-w-[150px] flex-col items-center whitespace-nowrap rounded-md border px-3 py-1 transition ${tone}`}
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
                <span className="whitespace-nowrap text-xs text-gray-200">
                  {STAGE_LABEL[id]}
                </span>
              </div>
              {stages[id].detail && (
                <div className="mt-0.5 max-w-[150px] truncate text-[10px] text-gray-400">
                  {stages[id].detail}
                </div>
              )}
            </div>
            {i < order.length - 1 && (
              <div className="mx-1 h-px w-4 shrink-0 bg-gray-700" aria-hidden />
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
  tts,
}: {
  review: VlmResponseBody | null;
  editPrompt: string;
  tts: { audio_url: string; audio_format: string; engine: string } | null;
}) {
  // Auto-play the review audio as soon as it's wired up. Browsers block
  // autoplay unless the user has interacted with the document first; here
  // they did (clicked the run button), so the play() call is allowed.
  const audioRef = useRef<HTMLAudioElement | null>(null);
  useEffect(() => {
    if (!tts) return;
    const el = audioRef.current;
    if (!el) return;
    el.src = tts.audio_url;
    el.load();
    void el.play().catch(() => {
      /* autoplay denied — user can press play manually */
    });
  }, [tts?.audio_url]);

  if (!review && !editPrompt && !tts) {
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
          <div className="flex items-center justify-between gap-2">
            <div className="text-[10px] uppercase tracking-wider text-gray-500">
              講評 ({review.metadata.model_id})
            </div>
            {tts && (
              <audio
                ref={audioRef}
                controls
                preload="auto"
                className="h-7 w-48 max-w-full"
                data-testid="review-audio"
              >
                <source src={tts.audio_url} type={`audio/${tts.audio_format === 'ogg_vorbis' ? 'ogg' : tts.audio_format}`} />
              </audio>
            )}
          </div>
          <div className="mt-0.5 whitespace-pre-wrap text-gray-200">{review.text}</div>
        </div>
      )}
    </div>
  );
}
