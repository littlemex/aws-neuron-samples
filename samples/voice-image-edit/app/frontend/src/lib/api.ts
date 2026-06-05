/**
 * backend/api/contracts.py と同じ形を TypeScript で表現する。
 * バックエンド側を変える時は両方を必ず更新する。
 *
 * 3 スロット (ASR / VLM / EDIT) すべての契約と HTTP クライアントを集約する。
 */
import { EDIT_API_PATH, STREAM_API_PATH } from './env';

// ---------------------------------------------------------------------------
// 共通
// ---------------------------------------------------------------------------

export interface EngineMetadata {
  model_id: string;
  latency_ms: number;
  request_id?: string;
  extra?: Record<string, unknown>;
}

export interface EngineErrorBody {
  error: {
    code: string;
    message: string;
    retryable: boolean;
    provider_detail?: Record<string, unknown>;
  };
}

// ---------------------------------------------------------------------------
// /api/edit/engines
// ---------------------------------------------------------------------------

export type SlotName = 'asr' | 'vlm' | 'edit' | 'generate' | 'tts';

export interface SlotInfo {
  engines: string[];
  default: string;
}

export type SlotsCatalog = Record<SlotName, SlotInfo>;

export async function fetchSlotsCatalog(): Promise<SlotsCatalog | null> {
  try {
    const res = await fetch(`${EDIT_API_PATH}/engines`, { cache: 'no-store' });
    if (!res.ok) return null;
    const json = (await res.json()) as { slots: SlotsCatalog };
    return json?.slots ?? null;
  } catch {
    return null;
  }
}

// ---------------------------------------------------------------------------
// ASR
// ---------------------------------------------------------------------------

export interface AsrSegment {
  start_ms: number;
  end_ms: number;
  text: string;
}

export interface AsrRequestBody {
  audio_b64: string;
  mime_type?: string;
  language?: string;
  engine?: string;
  request_id?: string;
}

export interface AsrResponseBody {
  engine: string;
  text: string;
  segments: AsrSegment[];
  metadata: EngineMetadata;
}

export async function invokeAsr(body: AsrRequestBody): Promise<AsrResponseBody> {
  return jsonPost<AsrResponseBody>(`${EDIT_API_PATH}/asr`, body);
}

// ---------------------------------------------------------------------------
// VLM
// ---------------------------------------------------------------------------

export type VlmMode = 'instruction' | 'review';

export interface VlmRequestBody {
  image_b64: string;
  prompt: string;
  mode?: VlmMode;
  engine?: string;
  request_id?: string;
}

export interface VlmResponseBody {
  engine: string;
  text: string;
  metadata: EngineMetadata;
}

export async function invokeVlm(body: VlmRequestBody): Promise<VlmResponseBody> {
  return jsonPost<VlmResponseBody>(`${EDIT_API_PATH}/vlm`, body);
}

// ---------------------------------------------------------------------------
// EDIT
// ---------------------------------------------------------------------------

export interface EditOptions {
  strength?: number;
  seed?: number | null;
  mask_b64?: string | null;
  negative_prompt?: string | null;
}

export interface EditRequestBody {
  image_b64: string;
  prompt: string;
  engine?: string;
  options?: EditOptions;
  request_id?: string;
}

export interface EditResponseBody {
  engine: string;
  // Nova Canvas / Trainium が返す画像は inline ではなく presigned S3 URL で配信する
  // (ALB Lambda Target の 1 MB response 上限を回避するため)。
  // image_format は将来 jpeg/webp などに広げる余地を残すための field。
  image_url: string;
  image_format: string;
  image_bytes?: number;
  metadata: EngineMetadata;
}

export async function invokeEdit(body: EditRequestBody): Promise<EditResponseBody> {
  return jsonPost<EditResponseBody>(`${EDIT_API_PATH}/edit`, body);
}

// ---------------------------------------------------------------------------
// GENERATE (text-to-image, no input image)
// ---------------------------------------------------------------------------

export interface GenerateOptions {
  seed?: number | null;
  negative_prompt?: string | null;
  aspect_ratio?: string | null;
}

export interface GenerateRequestBody {
  prompt: string;
  engine?: string;
  options?: GenerateOptions;
  request_id?: string;
}

// Generate's response shape mirrors Edit (image_url + metadata) so the
// frontend renderer can use a single display path; we alias the type.
export type GenerateResponseBody = EditResponseBody;

export async function invokeGenerate(body: GenerateRequestBody): Promise<GenerateResponseBody> {
  return jsonPost<GenerateResponseBody>(`${EDIT_API_PATH}/generate`, body);
}

// ---------------------------------------------------------------------------
// TTS (text -> audio). Response mirrors the edit/generate shape: the audio
// is staged to S3 and returned as a presigned URL so the JSON body stays
// small and the SSE pipeline does not have to carry MB-scale base64 audio.
// ---------------------------------------------------------------------------

export interface TtsOptions {
  voice?: string;
  language?: string;
  speed?: number;
  audio_format?: 'mp3' | 'ogg_vorbis' | 'pcm' | 'wav';
}

export interface TtsRequestBody {
  text: string;
  engine?: string;
  options?: TtsOptions;
  request_id?: string;
}

export interface TtsResponseBody {
  engine: string;
  audio_url: string;
  audio_format: string;
  audio_bytes?: number;
  metadata: EngineMetadata;
}

export async function invokeTts(body: TtsRequestBody): Promise<TtsResponseBody> {
  return jsonPost<TtsResponseBody>(`${EDIT_API_PATH}/tts`, body);
}

/**
 * presigned S3 URL を fetch して base64 に再変換する。
 * Stage 4 (VLM review) は VLM engine に image_b64 を渡す必要があるため、
 * EDIT の結果画像を一度 browser に落として b64 化してから VLM に投げる。
 */
export async function fetchImageAsBase64(url: string): Promise<string> {
  const res = await fetch(url, { cache: 'no-store' });
  if (!res.ok) {
    throw new Error(`failed to fetch edit result: http_${res.status}`);
  }
  const buf = await res.arrayBuffer();
  // chunk 化しないと長い base64 で stack overflow するブラウザがあるため分割。
  const bytes = new Uint8Array(buf);
  const chunkSize = 0x8000;
  let binary = '';
  for (let i = 0; i < bytes.length; i += chunkSize) {
    binary += String.fromCharCode.apply(null, Array.from(bytes.subarray(i, i + chunkSize)));
  }
  return btoa(binary);
}

// ---------------------------------------------------------------------------
// /stream/pipeline (P9): backend が VLM(instruction) -> EDIT -> VLM(review) を
//   順番に叩き、SSE で progress を吐く。frontend はこれを async generator で
//   消費する。
//
// SSE event 種:
//   pipeline_start    {request_id}
//   stage_start       {stage}
//   stage_complete    {stage, ...stage 固有フィールド}
//   stage_error       {stage, code, message}
//   pipeline_complete {request_id}
//
// stage_complete の payload は stage によって以下の形を取る:
//   - vlm_instruction: {engine, text, metadata}
//   - edit:            {engine, image_url, image_format, image_bytes, metadata}
//   - vlm_review:      {engine, text, metadata}
// ---------------------------------------------------------------------------

export interface StreamPipelineRequestBody {
  image_b64: string;
  user_instruction: string;
  vlm_engine?: string;
  edit_engine?: string;
  /** Run an extra TTS stage that reads the review aloud. Default false. */
  enable_tts?: boolean;
  tts_engine?: string;
  request_id?: string;
}

export type StreamPipelineEventType =
  | 'pipeline_start'
  | 'stage_start'
  | 'stage_complete'
  | 'stage_error'
  | 'pipeline_complete';

export interface StreamPipelineEvent {
  event: StreamPipelineEventType;
  data: Record<string, unknown>;
}

/**
 * /stream/pipeline を fetch streaming で開いて SSE event を yield する。
 * 呼び出し側は for-await で消費し、stage に応じて UI を更新する。
 *
 * AbortController を渡すとユーザー操作によるキャンセルが可能。
 */
export async function* streamPipeline(
  body: StreamPipelineRequestBody,
  signal?: AbortSignal,
): AsyncGenerator<StreamPipelineEvent, void, void> {
  const res = await fetch(`${STREAM_API_PATH}/pipeline`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'text/event-stream',
    },
    body: JSON.stringify(body),
    signal,
  });
  if (!res.ok || !res.body) {
    let detail = res.statusText;
    try {
      const json = await res.json();
      const err = (json as EngineErrorBody)?.error;
      if (err?.message) detail = `${err.code ?? 'http_' + res.status}: ${err.message}`;
    } catch {
      /* swallow */
    }
    throw new Error(`pipeline failed (${res.status}): ${detail}`);
  }
  const reader = res.body.getReader();
  const decoder = new TextDecoder('utf-8');
  let buffer = '';
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      // SSE は \n\n でメッセージ境界。\r\n も許容する。
      let sepIdx: number;
      while ((sepIdx = findSseBoundary(buffer)) !== -1) {
        const chunk = buffer.slice(0, sepIdx);
        buffer = buffer.slice(sepIdx).replace(/^(\r?\n){1,2}/, '');
        const evt = parseSseChunk(chunk);
        if (evt) yield evt;
      }
    }
    // tail (no trailing blank line) — ベストエフォートで捌く
    if (buffer.trim().length > 0) {
      const evt = parseSseChunk(buffer);
      if (evt) yield evt;
    }
  } finally {
    reader.releaseLock();
  }
}

// ---------------------------------------------------------------------------
// /stream/generate (text-to-image only): VLM is optional (translate stage);
// the ASR text becomes the prompt directly. stage_complete payload uses
// the same shape as the edit pipeline:
//   {engine, image_url, image_format, image_bytes, metadata}.
// ---------------------------------------------------------------------------

export interface StreamGeneratePipelineRequestBody {
  user_instruction: string;
  vlm_engine?: string;
  generate_engine?: string;
  /** Disable the upstream translate-mode VLM call even when the prompt
   *  is non-English. Useful when the operator wants the raw prompt fed
   *  to Stability verbatim. */
  skip_translate?: boolean;
  request_id?: string;
}

export async function* streamGeneratePipeline(
  body: StreamGeneratePipelineRequestBody,
  signal?: AbortSignal,
): AsyncGenerator<StreamPipelineEvent, void, void> {
  const res = await fetch(`${STREAM_API_PATH}/generate`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      Accept: 'text/event-stream',
    },
    body: JSON.stringify(body),
    signal,
  });
  if (!res.ok || !res.body) {
    let detail = res.statusText;
    try {
      const json = await res.json();
      const err = (json as EngineErrorBody)?.error;
      if (err?.message) detail = `${err.code ?? 'http_' + res.status}: ${err.message}`;
    } catch {
      /* swallow */
    }
    throw new Error(`generate pipeline failed (${res.status}): ${detail}`);
  }
  const reader = res.body.getReader();
  const decoder = new TextDecoder('utf-8');
  let buffer = '';
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buffer += decoder.decode(value, { stream: true });
      let sepIdx: number;
      while ((sepIdx = findSseBoundary(buffer)) !== -1) {
        const chunk = buffer.slice(0, sepIdx);
        buffer = buffer.slice(sepIdx).replace(/^(\r?\n){1,2}/, '');
        const evt = parseSseChunk(chunk);
        if (evt) yield evt;
      }
    }
    if (buffer.trim().length > 0) {
      const evt = parseSseChunk(buffer);
      if (evt) yield evt;
    }
  } finally {
    reader.releaseLock();
  }
}

function findSseBoundary(buf: string): number {
  const a = buf.indexOf('\n\n');
  const b = buf.indexOf('\r\n\r\n');
  if (a === -1 && b === -1) return -1;
  if (a === -1) return b;
  if (b === -1) return a;
  return Math.min(a, b);
}

function parseSseChunk(chunk: string): StreamPipelineEvent | null {
  let event: StreamPipelineEventType | null = null;
  const dataLines: string[] = [];
  for (const line of chunk.split(/\r?\n/)) {
    if (!line) continue;
    if (line.startsWith(':')) continue; // SSE comment / keep-alive
    const colon = line.indexOf(':');
    if (colon === -1) continue;
    const field = line.slice(0, colon).trim();
    let value = line.slice(colon + 1);
    if (value.startsWith(' ')) value = value.slice(1);
    if (field === 'event') event = value as StreamPipelineEventType;
    else if (field === 'data') dataLines.push(value);
  }
  if (!event) return null;
  let data: Record<string, unknown> = {};
  if (dataLines.length > 0) {
    try {
      data = JSON.parse(dataLines.join('\n')) as Record<string, unknown>;
    } catch {
      data = { raw: dataLines.join('\n') };
    }
  }
  return { event, data };
}

// ---------------------------------------------------------------------------
// 内部: JSON POST 共通
// ---------------------------------------------------------------------------

async function jsonPost<T>(url: string, body: unknown): Promise<T> {
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  const json = await res.json().catch(() => null);
  if (!res.ok) {
    const err = json as EngineErrorBody | null;
    const code = err?.error?.code ?? `http_${res.status}`;
    const msg = err?.error?.message ?? res.statusText;
    throw new Error(`${code}: ${msg}`);
  }
  return json as T;
}
