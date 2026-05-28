import { test, expect } from '@playwright/test';
import { CognitoLoginPage } from '../pages/CognitoLoginPage';

import * as fs from 'fs';
import * as path from 'path';
import { fileURLToPath } from 'url';

const TEST_EMAIL = process.env.TEST_USER_EMAIL!;
const TEST_PASSWORD = process.env.TEST_USER_PASSWORD!;

const __filename_e2e = fileURLToPath(import.meta.url);
const __dirname_e2e = path.dirname(__filename_e2e);
const SAMPLE_JA_WAV = path.join(__dirname_e2e, '..', 'fixtures', 'sample_ja.wav');

// NxD Inference 経由の Whisper-large-v3 が日本語音声を正しく書き起こせる
// ことを UI 経由 (= CloudFront → API → Trainium /transcribe) で確認する。
//
// 旧 torch_neuronx.trace 版は "in in in..." の繰り返しループに落ちていた。
// 期待値: 「私は東京に住んでいます。今日の天気はとても良いですね。」
//   (sample_ja.wav は gtts で生成した日本語 16 kHz mono WAV)
test.describe('voice-image-edit ASR /api/edit/asr (trainium / NxD)', () => {
  test.setTimeout(120_000);

  test('日本語 WAV で /api/edit/asr engine=trainium が正しく書き起こす', async ({ page, context }) => {
    await context.clearCookies();

    // Cognito ログインを 1 度だけ通す。page.request は cookie jar を共有するので
    // CF Function (cf_session) チェックが透過する。
    await page.goto('/edit', { waitUntil: 'networkidle' });
    const cognito = new CognitoLoginPage(page);
    await page.waitForLoadState('networkidle');
    await cognito.expectVisible();
    await cognito.login(TEST_EMAIL, TEST_PASSWORD);
    await page.waitForURL((u) => !u.host.includes('amazoncognito.com'), { timeout: 30_000 });
    await page.waitForLoadState('networkidle');

    // 16 kHz mono WAV (gtts → miniaudio decode) を base64 化して JSON で投げる。
    const wavBytes = fs.readFileSync(SAMPLE_JA_WAV);
    const audioB64 = wavBytes.toString('base64');

    const res = await page.request.post('/api/edit/asr', {
      data: {
        engine: 'trainium',
        audio_b64: audioB64,
        mime_type: 'audio/wav',
        language: 'ja',
      },
      headers: { 'content-type': 'application/json' },
      timeout: 60_000,
    });

    expect(res.status(), '/api/edit/asr should be 200').toBe(200);
    const body = await res.json();

    // text は string で空ではない。
    expect(typeof body.text, 'response.text should be string').toBe('string');
    expect(body.text.length, 'response.text should be non-empty').toBeGreaterThan(0);

    // ループ検知: 同じ単語 3 連続 (例: "in in in", "は は は") は明確な失敗。
    expect(body.text, 'response.text must not contain 3+ repeated tokens').not.toMatch(/(\b\S+\b)(?:\s+\1){2,}/);
    expect(body.text, 'response.text must not contain 3+ repeated CJK chars').not.toMatch(/(.)\1{4,}/);

    // sample_ja.wav は prepare_sample_ja_wav.sh が gtts で生成した
    //   「こんにちは。これは音声認識のテストです。」
    // を含む。ASR の表記揺れに強いキーワード判定で確認する。
    const hasKeyJP = /こんにち|音声|認識|テスト/.test(body.text);
    expect(
      hasKeyJP,
      `expected JA keyword in transcription, got: ${body.text}`,
    ).toBe(true);

    // segments は配列で、最低 1 件返る。
    expect(Array.isArray(body.segments), 'response.segments should be an array').toBe(true);
    expect(body.segments.length, 'response.segments should be non-empty').toBeGreaterThan(0);
  });
});
