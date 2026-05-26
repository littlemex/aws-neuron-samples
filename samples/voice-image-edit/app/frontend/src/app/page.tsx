import Link from 'next/link';

export default function Home() {
  return (
    <main className="mx-auto max-w-2xl space-y-6 p-8">
      <h1 className="text-3xl font-semibold">voice-image-edit</h1>
      <p className="text-gray-300">
        音声で画像を編集するデモ。3 スロット (ASR / VLM / EDIT) を Bedrock 系 / 自前サービング系で
        切り替えながら動作確認できます。
      </p>
      <div className="flex gap-3">
        <Link
          href="/edit"
          className="rounded bg-blue-600 px-5 py-2 text-white hover:bg-blue-500"
        >
          /edit を開く
        </Link>
        <Link
          href="/manage"
          className="rounded border border-gray-700 px-5 py-2 text-gray-200 hover:bg-gray-800"
        >
          /manage でエンジンを切替
        </Link>
      </div>
    </main>
  );
}
