'use client';

import { useCallback, useRef, useState } from 'react';

interface Props {
  onPick: (b64: string, dataUrl: string, fileName: string) => void;
  // 親レイアウトに高さを合わせる用。未指定なら h-full w-full。
  className?: string;
}

interface Picked {
  dataUrl: string;
  fileName: string;
  sizeBytes: number;
}

export function ImageDropzone({ onPick, className }: Props) {
  const [hover, setHover] = useState(false);
  const [picked, setPicked] = useState<Picked | null>(null);
  const inputRef = useRef<HTMLInputElement>(null);

  const handle = useCallback(
    async (file: File) => {
      const reader = new FileReader();
      const dataUrl: string = await new Promise((resolve, reject) => {
        reader.onload = () => resolve(reader.result as string);
        reader.onerror = reject;
        reader.readAsDataURL(file);
      });
      const b64 = dataUrl.split(',')[1] ?? '';
      setPicked({ dataUrl, fileName: file.name, sizeBytes: file.size });
      onPick(b64, dataUrl, file.name);
    },
    [onPick],
  );

  return (
    <div
      onDragOver={(e) => {
        e.preventDefault();
        setHover(true);
      }}
      onDragLeave={() => setHover(false)}
      onDrop={(e) => {
        e.preventDefault();
        setHover(false);
        const f = e.dataTransfer.files?.[0];
        f && handle(f);
      }}
      onClick={() => inputRef.current?.click()}
      className={`relative flex cursor-pointer items-center justify-center overflow-hidden rounded-lg border-2 border-dashed transition ${
        hover
          ? 'border-blue-400 bg-blue-950/30'
          : picked
          ? 'border-gray-700 bg-black/40'
          : 'border-gray-600 bg-gray-900/40 hover:border-gray-400'
      } ${className ?? 'h-full w-full'}`}
    >
      {picked ? (
        <>
          {/* picked.dataUrl は data: URL なので next/image は使わず素の img で十分。 */}
          {/* eslint-disable-next-line @next/next/no-img-element */}
          <img
            src={picked.dataUrl}
            alt="picked preview"
            className="max-h-full max-w-full object-contain"
          />
          <div className="pointer-events-none absolute bottom-2 left-2 right-2 truncate rounded bg-black/70 px-2 py-1 text-xs text-gray-100">
            {picked.fileName} · {(picked.sizeBytes / 1024 / 1024).toFixed(2)} MB
          </div>
        </>
      ) : (
        <div className="text-center">
          <p className="text-sm text-gray-300">画像をドロップ または クリック</p>
          <p className="mt-1 text-xs text-gray-500">PNG / JPEG / WebP</p>
        </div>
      )}
      <input
        ref={inputRef}
        type="file"
        accept="image/*"
        data-testid="image-file-input"
        // sr-only keeps the input in the layout / accessibility tree
        // (so screen readers and Playwright's setInputFiles can reach
        // it) while remaining visually hidden.
        className="sr-only"
        onChange={(e) => {
          const f = e.target.files?.[0];
          f && handle(f);
        }}
      />
    </div>
  );
}
