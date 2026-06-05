'use client';

import Link from 'next/link';
import { type SlotName } from '@/lib/api';
import { useEngineConfig } from '@/lib/engineConfig';

const SLOT_LABELS: Record<SlotName, { title: string; description: string }> = {
  asr: {
    title: 'ASR',
    description: '音声 → テキスト指示。録音した発話をどのモデルで書き起こすかを選択する。',
  },
  vlm: {
    title: 'VLM',
    description:
      '画像 + テキスト → 編集プロンプト / レビュー。指示生成と編集後レビューに使う。',
  },
  edit: {
    title: 'EDIT',
    description: '画像 + プロンプト → 編集後画像。実際の画像編集を担当する。',
  },
  generate: {
    title: 'GENERATE',
    description:
      'プロンプト → 新規画像。画像入力なしのテキスト→画像生成 (Stability AI on Bedrock)。',
  },
  tts: {
    title: 'TTS',
    description:
      'テキスト → 音声。VLM の講評を読み上げるオプションステージで使う (Bedrock 系は Polly、Trainium 系は self-hosted XTTS / F5-TTS)。',
  },
};

const SLOTS: SlotName[] = ['asr', 'vlm', 'edit', 'generate', 'tts'];

export default function ManagePage() {
  const { catalog, catalogError, catalogLoading, config, resolved, setSlot, clear } =
    useEngineConfig();

  return (
    <main className="mx-auto max-w-3xl space-y-6 p-6">
      <header className="flex items-center justify-between">
        <h1 className="text-2xl font-semibold">エンジン管理 / manage</h1>
        <Link href="/edit" className="text-sm text-blue-400 hover:underline">
          /edit に戻る →
        </Link>
      </header>

      <p className="text-sm text-gray-400">
        3 スロット (ASR / VLM / EDIT) ごとに使う実装を選びます。設定はブラウザの
        <code className="mx-1 rounded bg-gray-800 px-1">localStorage</code>
        に保存され、リクエストごとに送信されます。
      </p>

      {catalogLoading && (
        <p className="text-sm text-gray-400">バックエンドからエンジン一覧を取得中…</p>
      )}
      {catalogError && (
        <p className="rounded border border-red-700 bg-red-950 p-3 text-sm text-red-300">
          {catalogError} (Stage 2 が未デプロイ、もしくは ALB rule が出来ていない可能性があります)
        </p>
      )}

      {SLOTS.map((slot) => {
        const info = catalog?.[slot];
        const options = info?.engines ?? [];
        const labelInfo = SLOT_LABELS[slot];
        const selected = config[slot];
        const effective = resolved[slot];

        return (
          <section
            key={slot}
            className="rounded-lg border border-gray-800 bg-gray-950 p-4"
          >
            <div className="mb-3 flex items-baseline justify-between">
              <h2 className="text-lg font-medium">
                {labelInfo.title}
                <span className="ml-2 text-xs text-gray-500">/{slot}</span>
              </h2>
              <div className="text-xs text-gray-500">
                effective: <code className="text-gray-300">{effective ?? '(unset)'}</code>
              </div>
            </div>
            <p className="mb-3 text-sm text-gray-400">{labelInfo.description}</p>

            {options.length === 0 ? (
              <p className="text-sm text-gray-500">
                バックエンドから候補が取得できていません。
              </p>
            ) : (
              <div className="space-y-2">
                <label className="flex items-center gap-2 text-sm">
                  <input
                    type="radio"
                    name={`slot-${slot}`}
                    checked={!selected}
                    onChange={() => setSlot(slot, undefined)}
                  />
                  <span className="text-gray-300">
                    バックエンド既定値を使う
                    <span className="ml-2 text-xs text-gray-500">
                      ({info?.default ?? '?'})
                    </span>
                  </span>
                </label>
                {options.map((name) => (
                  <label key={name} className="flex items-center gap-2 text-sm">
                    <input
                      type="radio"
                      name={`slot-${slot}`}
                      checked={selected === name}
                      onChange={() => setSlot(slot, name)}
                    />
                    <code className="text-gray-200">{name}</code>
                    {info?.default === name && (
                      <span className="text-xs text-gray-500">(default)</span>
                    )}
                  </label>
                ))}
              </div>
            )}
          </section>
        );
      })}

      <div className="flex items-center gap-3 pt-2">
        <button
          onClick={clear}
          className="rounded border border-gray-700 px-3 py-1.5 text-sm text-gray-300 hover:bg-gray-800"
        >
          選択をリセット (全スロット既定値に戻す)
        </button>
        <Link
          href="/edit"
          className="rounded bg-blue-600 px-3 py-1.5 text-sm text-white hover:bg-blue-500"
        >
          /edit でこの設定を試す
        </Link>
      </div>
    </main>
  );
}
