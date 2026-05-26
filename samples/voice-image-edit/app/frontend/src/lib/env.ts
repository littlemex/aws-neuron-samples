/**
 * 公開環境変数。NEXT_PUBLIC_ prefix が必要なものはここでだけ参照する。
 * 値そのものは next build 時に固定される (デプロイ時に注入)。
 */

export const EDIT_API_PATH = process.env.NEXT_PUBLIC_EDIT_API_PATH ?? '/api/edit';
// P9: SSE backend が CloudFront + ALB の /stream/* で受ける。
// frontend は同 origin から /stream/pipeline を fetch するため絶対 URL は不要。
export const STREAM_API_PATH = process.env.NEXT_PUBLIC_STREAM_API_PATH ?? '/stream';
