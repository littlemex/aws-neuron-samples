# Voice-driven Image Edit E2E

UI を介さずに 3 つのモデルがバックエンドで連携することを検証する end-to-end テストです。
demo orchestrator (UI 側) は別途用意する前提で、このテストが「3 モデルをどう連携させるべきか」の仕様にもなっています。

## パイプライン

```
[1] sample_ja.wav (16kHz mono int16)
        │
        ▼
   Whisper-large-v3 (ws://:8765/whisper-neuron/ws)
        │ 日本語テキスト指示
        ▼
[2] Qwen3-VL-8B-Thinking (http://:8090/v1/chat/completions)
        │  入力: 指示テキスト + before 画像 (256x256 シャツ想定)
        │  出力: VTON 用の {prompt, negative_prompt} (JSON)
        ▼
[3] Qwen-Image-Edit (http://:8081/infer)
        │  入力: before 画像 + prompt
        │  出力: 編集後 PNG (after 画像)
        ▼
[4] Qwen3-VL-8B-Thinking (再利用, 画像理解)
        │  入力: after 画像 + 元の指示
        │  出力: 「指示通りに編集できたか」の日本語説明
        ▼
   PASS / FAIL
```

## 整合性チェック (各 stage の出力 spec)

| stage | 出力 | 検証項目 |
|---|---|---|
| 1 | text | 日本語文字 (ひらがな/カタカナ/漢字) を含む |
| 2 | prompt + negative_prompt | JSON でパース可能、prompt が日本語、prompt が非空 |
| 3 | PNG bytes | HTTP 200、PNG マジック (`89 50 4E 47 ...`) |
| 4 | text | 日本語文字を含む (=画像が読めて感想を返した) |

## 使い方

事前に以下のサーバーが立っていること:

```bash
bash start_all.sh
bash status.sh        # qwen3=8090 / vton=8081 / whisper=8765 が listening + /health 200
```

まず日本語サンプル wav を 1 度だけ生成 (既存なら不要):

```bash
bash ../models/whisper/prepare_sample_ja_wav.sh
# -> ../models/whisper/_assets/sample_ja.wav
```

E2E 実行:

```bash
bash demo/demo_e2e.sh
# 失敗時は最初に落ちた stage で exit
# 成功時は最後に SUMMARY を出力
```

ポートを変えている場合:

```bash
bash demo/demo_e2e.sh --qwen3-port 18090 --vton-port 18081 --whisper-port 18765
```

別の wav を使う場合:

```bash
bash demo/demo_e2e.sh --wav /path/to/your_ja_16k_mono_int16.wav
```

## 既知の制約

- Qwen3-VL の応答が JSON でなく自然文を返した場合は stage 2 が FAIL します。`{...}` のみを抽出する正規表現は入れていますが、システムプロンプトに従わない場合があります。
- Qwen-Image-Edit は画像編集に時間がかかる (数十秒〜) のため curl タイムアウトを 900 秒にしています。
- before 画像はテスト用に zlib + struct で生成した 256x256 単色 PNG です。実運用では実物の服画像に差し替えてください。
- Whisper は短い wav に対して "I I I I..." のような hallucination を出すことがあります。stage 1 では日本語文字だけを抽出し、それでも有効な指示にならない (例: 同じ語の単純繰り返し) 場合は、E2E のために組み込んでいる固定フォールバック指示「このシャツの色を朝焼けの空のような暖色のオレンジに変えてください。」に差し替えます。Whisper の認識精度自体は `../models/whisper/test.sh` で検証してください。
