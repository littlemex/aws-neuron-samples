"""Trainium 系 ASR エンジン: Whisper 等の自前サービングに対する薄いプロキシ。

接続先は環境変数で受け取る。ハードコード禁止。
- TRAINIUM_ASR_URL  (HTTP の transcribe エンドポイント想定。例: http://internal-...:8000/transcribe)
- TRAINIUM_ASR_MODEL_ID (default: openai/whisper-large-v3)
- TRAINIUM_ASR_TIMEOUT_SECONDS (default: 60)

リクエスト本体は raw audio bytes を ``application/octet-stream`` で送る。サーバ側は
``X-Sample-Rate`` / ``X-Mime-Type`` ヘッダ + ボディを見て decode する想定。
レスポンスは ``{"text": str, "segments": [{"start_ms", "end_ms", "text"}, ...]}`` の JSON。
"""
from __future__ import annotations

import json
import time

import urllib3

from contracts import (
    AsrRequest,
    AsrResponse,
    AsrSegment,
    EngineError,
)
from engines.asr.base import AsrEngine
from engines._common import (
    build_metadata,
    decode_audio_b64,
    env_float,
    env_required,
    raise_for_status,
    whisper_language,
)


class TrainiumAsrEngine(AsrEngine):
    name = "trainium"

    def __init__(self) -> None:
        import os

        self.endpoint = env_required("TRAINIUM_ASR_URL")
        self.model_id = os.environ.get(
            "TRAINIUM_ASR_MODEL_ID", "openai/whisper-large-v3"
        )
        self.timeout = env_float("TRAINIUM_ASR_TIMEOUT_SECONDS", 60.0)
        self._http = urllib3.PoolManager()

    def invoke(self, req: AsrRequest) -> AsrResponse:
        start = time.monotonic()
        audio_bytes = decode_audio_b64(req.audio_b64, allow_empty=True)

        headers = {
            "Content-Type": "application/octet-stream",
            "X-Mime-Type": req.mime_type,
        }
        whisper_lang = whisper_language(req.language)
        if whisper_lang:
            headers["X-Language"] = whisper_lang
        sample_rate = _extract_sample_rate(req.mime_type)
        if sample_rate:
            headers["X-Sample-Rate"] = str(sample_rate)

        try:
            resp = self._http.request(
                "POST",
                self.endpoint,
                body=audio_bytes,
                headers=headers,
                timeout=urllib3.Timeout(connect=5.0, read=self.timeout),
                retries=False,
            )
        except urllib3.exceptions.HTTPError as exc:
            raise EngineError(
                "provider_error",
                f"trainium asr request failed: {exc}",
                retryable=True,
            ) from exc

        raise_for_status(resp, label="trainium asr")

        try:
            payload = json.loads(resp.data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise EngineError(
                "provider_invalid_response",
                f"trainium asr returned non-JSON body: {exc}",
            ) from exc

        text = payload.get("text")
        if not isinstance(text, str):
            raise EngineError(
                "provider_invalid_response",
                "trainium asr response missing 'text'",
                provider_detail={"keys": list(payload.keys())},
            )

        segments = []
        for raw in payload.get("segments") or []:
            if not isinstance(raw, dict):
                continue
            segments.append(
                AsrSegment(
                    start_ms=int(raw.get("start_ms", 0)),
                    end_ms=int(raw.get("end_ms", 0)),
                    text=str(raw.get("text", "")),
                )
            )

        return AsrResponse(
            engine=self.name,
            text=text,
            segments=segments,
            metadata=build_metadata(
                model_id=self.model_id,
                start_monotonic=start,
                request_id=req.request_id,
                extra={"endpoint": self.endpoint},
            ),
        )


def _extract_sample_rate(mime_type: str) -> int | None:
    if not mime_type or "rate=" not in mime_type:
        return None
    try:
        return int(mime_type.split("rate=")[1].split(";")[0].strip())
    except (ValueError, IndexError):
        return None
