/**
 * マイクから録音 → 16kHz mono int16 LE PCM に変換 → base64 を返すヘルパー。
 *
 * 設計メモ:
 *   - MediaRecorder で webm/opus を一旦取り、AudioContext.decodeAudioData →
 *     OfflineAudioContext で 16kHz mono に resample → Float32 を Int16 LE にパック
 *     → base64 にする、という最小実装。
 *   - Lambda 側で ffmpeg を持たないために、フォーマット変換は完全にブラウザ側で完結させる。
 *   - mime_type は固定で "audio/pcm; rate=16000" を返し、サーバ側 (Bedrock Transcribe /
 *     Trainium Whisper) はこの形だけを処理する契約。
 */
'use client';

const TARGET_SAMPLE_RATE = 16000;
export const TARGET_MIME_TYPE = `audio/pcm; rate=${TARGET_SAMPLE_RATE}`;

export interface PcmRecording {
  audioB64: string;
  mimeType: string;
  durationMs: number;
}

export class PcmRecorder {
  private mediaRecorder: MediaRecorder | null = null;
  private stream: MediaStream | null = null;
  private chunks: Blob[] = [];
  private recordingMimeType: string = 'audio/webm';

  async start(): Promise<void> {
    if (this.mediaRecorder) {
      throw new Error('already recording');
    }
    const stream = await navigator.mediaDevices.getUserMedia({
      audio: {
        channelCount: 1,
        echoCancellation: true,
        noiseSuppression: true,
      },
    });
    this.stream = stream;
    this.recordingMimeType = pickMimeType();
    const recorder = new MediaRecorder(stream, { mimeType: this.recordingMimeType });
    this.chunks = [];
    recorder.ondataavailable = (ev) => {
      if (ev.data && ev.data.size > 0) this.chunks.push(ev.data);
    };
    this.mediaRecorder = recorder;
    recorder.start(250);
  }

  async stop(): Promise<PcmRecording> {
    const recorder = this.mediaRecorder;
    if (!recorder) throw new Error('not recording');
    const stopped = new Promise<void>((resolve) => {
      recorder.onstop = () => resolve();
    });
    recorder.stop();
    await stopped;
    this.stream?.getTracks().forEach((t) => t.stop());
    this.mediaRecorder = null;
    this.stream = null;

    const blob = new Blob(this.chunks, { type: this.recordingMimeType });
    this.chunks = [];
    const arrayBuffer = await blob.arrayBuffer();
    const decoded = await decodeToMono16k(arrayBuffer);
    const pcm = floatTo16BitPCM(decoded.data);
    const audioB64 = bytesToBase64(new Uint8Array(pcm.buffer));
    return {
      audioB64,
      mimeType: TARGET_MIME_TYPE,
      durationMs: Math.round((decoded.length / TARGET_SAMPLE_RATE) * 1000),
    };
  }

  cancel(): void {
    if (this.mediaRecorder && this.mediaRecorder.state !== 'inactive') {
      try {
        this.mediaRecorder.stop();
      } catch {
        /* ignore */
      }
    }
    this.stream?.getTracks().forEach((t) => t.stop());
    this.mediaRecorder = null;
    this.stream = null;
    this.chunks = [];
  }
}

function pickMimeType(): string {
  const candidates = [
    'audio/webm;codecs=opus',
    'audio/webm',
    'audio/mp4',
    'audio/ogg;codecs=opus',
  ];
  for (const m of candidates) {
    if (typeof MediaRecorder !== 'undefined' && MediaRecorder.isTypeSupported(m)) {
      return m;
    }
  }
  return 'audio/webm';
}

async function decodeToMono16k(buf: ArrayBuffer): Promise<{ data: Float32Array; length: number }> {
  const Ctx: typeof AudioContext =
    (window as unknown as { AudioContext: typeof AudioContext; webkitAudioContext?: typeof AudioContext })
      .AudioContext ||
    (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
  const tmp = new Ctx();
  let audioBuffer: AudioBuffer;
  try {
    audioBuffer = await tmp.decodeAudioData(buf.slice(0));
  } finally {
    tmp.close().catch(() => undefined);
  }
  const offline = new OfflineAudioContext(
    1,
    Math.ceil((audioBuffer.duration * TARGET_SAMPLE_RATE)),
    TARGET_SAMPLE_RATE,
  );
  const source = offline.createBufferSource();
  source.buffer = audioBuffer;
  source.connect(offline.destination);
  source.start(0);
  const rendered = await offline.startRendering();
  const channel = rendered.getChannelData(0);
  return { data: channel, length: channel.length };
}

function floatTo16BitPCM(input: Float32Array): Int16Array {
  const out = new Int16Array(input.length);
  for (let i = 0; i < input.length; i++) {
    const s = Math.max(-1, Math.min(1, input[i]));
    out[i] = s < 0 ? Math.round(s * 0x8000) : Math.round(s * 0x7fff);
  }
  return out;
}

function bytesToBase64(bytes: Uint8Array): string {
  // chunk to avoid call-stack overflow on large buffers
  const CHUNK = 0x8000;
  let binary = '';
  for (let i = 0; i < bytes.length; i += CHUNK) {
    binary += String.fromCharCode.apply(null, Array.from(bytes.subarray(i, i + CHUNK)));
  }
  return btoa(binary);
}
