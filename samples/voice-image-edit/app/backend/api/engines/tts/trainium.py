"""Trainium TTS engine: thin HTTP proxy to a self-hosted on-device TTS server.

Mirrors the trainium VLM / ASR / Edit engines: when the operator has a
TTS server running on the Trainium instance (e.g. F5-TTS or XTTS behind
an OpenAI-compatible-ish HTTP endpoint), point ``TRAINIUM_TTS_URL`` at it
and this engine forwards requests there.

Wire format (configurable):
  - request:  POST {TRAINIUM_TTS_URL} with JSON
              {"text": str, "voice"?: str, "language"?: str, "speed"?: float,
               "audio_format"?: str}
  - response: JSON {"audio_b64": "<base64>", "audio_format": "mp3"|"wav"|...}

When ``TRAINIUM_TTS_URL`` is not set, ``synthesize`` raises
``EngineError("config_missing", ...)`` so the registry stays valid (you
can always *select* the engine; you just cannot call it until the URL is
configured).
"""
from __future__ import annotations

import json
import os
import time
from typing import Any, Optional

import urllib3

from contracts import EngineError, TtsRequest, TtsResponse
from engines._common import build_metadata, env_float, raise_for_status
from engines.tts.base import TtsEngine


class TrainiumTtsEngine(TtsEngine):
    name = "trainium"

    def __init__(self, engine_name: Optional[str] = None) -> None:
        # URL is read lazily inside synthesize() so the registry can list
        # this engine even before TRAINIUM_TTS_URL is wired up. That way
        # the operator can flip to it as soon as the server comes online,
        # without restarting the API.
        self.endpoint: Optional[str] = None
        self.model_id = os.environ.get("TRAINIUM_TTS_MODEL_ID") or "trainium-tts"
        self.timeout = env_float("TRAINIUM_TTS_TIMEOUT_SECONDS", 60.0)
        self.api_key = os.environ.get("TRAINIUM_TTS_API_KEY")
        if engine_name:
            self.name = engine_name
        self._http = urllib3.PoolManager()

    def _resolve_endpoint(self) -> str:
        # Re-read every call to honour env updates without service restart.
        url = os.environ.get("TRAINIUM_TTS_URL")
        if not url:
            raise EngineError(
                "config_missing",
                "TRAINIUM_TTS_URL env var is required",
            )
        return url

    def synthesize(self, req: TtsRequest) -> TtsResponse:
        start = time.monotonic()
        url = self._resolve_endpoint()

        body: dict[str, Any] = {"text": req.text}
        if req.options.voice:
            body["voice"] = req.options.voice
        if req.options.language:
            body["language"] = req.options.language
        if req.options.speed is not None:
            body["speed"] = float(req.options.speed)
        if req.options.audio_format:
            body["audio_format"] = req.options.audio_format

        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        try:
            resp = self._http.request(
                "POST",
                url,
                body=json.dumps(body).encode("utf-8"),
                headers=headers,
                timeout=urllib3.Timeout(connect=5.0, read=self.timeout),
                retries=False,
            )
        except urllib3.exceptions.HTTPError as exc:
            raise EngineError(
                "provider_error",
                f"trainium tts request failed: {exc}",
                retryable=True,
            ) from exc

        raise_for_status(resp, label="trainium tts")

        try:
            payload = json.loads(resp.data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise EngineError(
                "provider_invalid_response",
                f"trainium tts returned non-JSON: {exc}",
            ) from exc

        audio_b64 = payload.get("audio_b64")
        if not audio_b64:
            raise EngineError(
                "provider_invalid_response",
                "trainium tts response missing 'audio_b64'",
                provider_detail={"keys": list(payload.keys())},
            )
        audio_format = payload.get("audio_format") or "mp3"

        return TtsResponse(
            engine=self.name,
            audio_b64=audio_b64,
            audio_format=audio_format,
            metadata=build_metadata(
                model_id=payload.get("model_id") or self.model_id,
                start_monotonic=start,
                request_id=req.request_id,
                extra={
                    "endpoint": url,
                    "voice": payload.get("voice"),
                    "language": payload.get("language"),
                },
            ),
        )
