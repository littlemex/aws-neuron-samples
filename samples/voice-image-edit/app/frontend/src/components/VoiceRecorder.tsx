'use client';

import { useCallback, useRef, useState } from 'react';
import { invokeAsr } from '@/lib/api';
import { PcmRecorder } from '@/lib/audio';
import { useEngineConfig } from '@/lib/engineConfig';

interface Props {
  onTranscript: (text: string) => void;
}

type Status = 'idle' | 'recording' | 'transcribing' | 'done' | 'error';

// 1 画面 UI 用のコンパクトな録音ボタン。
// - ボタン 1 つでトグル (idle → 録音 → 停止 → 文字起こし → idle)
// - エラー / 状態は親要素の小さなテキスト枠に出す
// - 文字起こし結果は親 (EditPage) の userInstruction 経由でテキストエリアに反映される。
//   ここでは独自表示しない (重複防止)。
export function VoiceRecorder({ onTranscript }: Props) {
  const { resolved } = useEngineConfig();
  const [status, setStatus] = useState<Status>('idle');
  const [error, setError] = useState<string | null>(null);
  const recorderRef = useRef<PcmRecorder | null>(null);

  const start = useCallback(async () => {
    setError(null);
    const rec = new PcmRecorder();
    try {
      await rec.start();
    } catch (e) {
      setError(`mic error: ${e instanceof Error ? e.message : String(e)}`);
      return;
    }
    recorderRef.current = rec;
    setStatus('recording');
  }, []);

  const stopAndTranscribe = useCallback(async () => {
    const rec = recorderRef.current;
    if (!rec) return;
    setStatus('transcribing');
    try {
      const recording = await rec.stop();
      recorderRef.current = null;
      const out = await invokeAsr({
        audio_b64: recording.audioB64,
        mime_type: recording.mimeType,
        engine: resolved.asr,
      });
      onTranscript(out.text);
      setStatus('done');
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
      setStatus('error');
    }
  }, [onTranscript, resolved.asr]);

  const onClick = () => {
    if (status === 'recording') {
      stopAndTranscribe().catch(() => undefined);
    } else if (status !== 'transcribing') {
      start().catch(() => undefined);
    }
  };

  const label = (() => {
    switch (status) {
      case 'recording':
        return '停止して文字起こし';
      case 'transcribing':
        return '文字起こし中…';
      case 'done':
        return '再録音';
      case 'error':
        return '再録音';
      default:
        return '録音';
    }
  })();

  const cls = (() => {
    if (status === 'recording')
      return 'bg-red-600 hover:bg-red-500 text-white animate-pulse';
    if (status === 'transcribing') return 'bg-gray-700 text-gray-300 cursor-wait';
    return 'bg-blue-600 hover:bg-blue-500 text-white';
  })();

  return (
    <div className="flex flex-col gap-1">
      <button
        type="button"
        onClick={onClick}
        disabled={status === 'transcribing'}
        className={`w-full rounded-lg px-4 py-3 text-sm font-medium transition ${cls}`}
      >
        <span className="inline-flex items-center justify-center gap-2">
          {status === 'recording' && (
            <span className="h-2 w-2 rounded-full bg-white" />
          )}
          {label}
        </span>
      </button>
      {error && (
        <div className="truncate rounded border border-red-700 bg-red-950 px-2 py-1 text-xs text-red-300">
          {error}
        </div>
      )}
    </div>
  );
}
