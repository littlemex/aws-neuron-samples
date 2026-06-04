# standalone-page

Next.js (App Router) プロジェクトに 1 ファイル置くだけで、neuron-anatomy backend を
ブラウザから確認できる最小デモ。

## 使い方

1. 任意の Next.js プロジェクト (App Router) を用意。
2. `package.json` に依存を追加:
   ```json
   {
     "dependencies": {
       "@aws-neuron-samples/neuron-anatomy": "file:../../samples/neuron-anatomy/frontend"
     }
   }
   ```
3. `src/app/neuron/page.tsx` にこのファイルをコピー。
4. `npm run dev` で `/neuron` にアクセス。

## backend の繋ぎ方

- 既存 voice-image-edit の CloudFront を経由する場合: `base="/neuron"` のまま。
- ローカル開発で backend を別ポートで動かす場合: Next.js の `next.config.js`
  で `/neuron/*` を `http://localhost:8810` に rewrite するか、
  `<NeuronDrawer base="http://localhost:8810/neuron" />` で直叩き。
