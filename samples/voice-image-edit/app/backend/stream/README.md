# voice-image-edit-stream (P8 skeleton)

ALB の `/stream/*` ルールから IP target で受ける FastAPI/uvicorn 常駐サービス。
P8 ではエンドポイント疎通までを担当し、4 段パイプラインの progress を SSE で
押し出す本実装は P9 で別途行う。

## エンドポイント

- `GET /stream/health` - JSON 200 (ALB health check + Playwright sanity)
- `GET /stream/echo?message=...&count=N&interval_ms=M` - text/event-stream で
  N 件の `tick` イベントを送り、最後に `done` を送ってクローズ

## ローカル起動 (動作確認用)

```bash
cd /opt/voice-image-edit/stream
./venv/bin/uvicorn app:app --host 0.0.0.0 --port 8800
curl -N http://127.0.0.1:8800/stream/echo?message=hi&count=3
```

## EC2 配置 (P8-C)

`/opt/voice-image-edit/stream/` 以下に展開し、
`/etc/systemd/system/voice-image-edit-stream.service` で常駐。
