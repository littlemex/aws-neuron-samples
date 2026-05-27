"""Bedrock 系 ASR エンジン (Amazon Transcribe Streaming / Bedrock Nova Sonic)。

backend を切り替えられるが、現在は ``transcribe`` のみ実装済み。``nova_sonic`` は
双方向ストリーミング (InvokeModelWithBidirectionalStream) が必要なため P5 以降で対応する。

環境変数:
  - BEDROCK_REGION (必須): Transcribe / Bedrock を呼ぶリージョン。
  - BEDROCK_ASR_BACKEND: ``transcribe`` (default) / ``nova_sonic``
  - BEDROCK_NOVA_SONIC_MODEL_ID: nova_sonic 用 (default: amazon.nova-sonic-v1:0)

入力音声: 16kHz mono int16 LE PCM を期待 (mime_type ``audio/pcm; rate=16000``)。
他フォーマットを受け取った場合は ``invalid_request`` を返す (Lambda で ffmpeg を持たない方針)。
"""
from __future__ import annotations

import asyncio
import os
import time

from contracts import (
    AsrRequest,
    AsrResponse,
    AsrSegment,
    EngineError,
)
from engines.asr.base import AsrEngine
from engines._common import build_metadata, decode_audio_b64, env_required

_PCM_MIME_PREFIX = "audio/pcm"


class BedrockAsrEngine(AsrEngine):
    """Amazon Transcribe Streaming / Bedrock Nova Sonic を切り替えられる ASR。"""

    name = "bedrock_transcribe"

    def __init__(
        self,
        backend: str | None = None,
        engine_name: str | None = None,
    ) -> None:
        self.region = env_required("BEDROCK_REGION", "AWS_REGION")
        self.backend = backend or os.environ.get(
            "BEDROCK_ASR_BACKEND", "transcribe"
        )
        if self.backend not in {"transcribe", "nova_sonic"}:
            raise EngineError(
                "config_missing",
                f"unknown BEDROCK_ASR_BACKEND: {self.backend}",
            )
        self.name = engine_name or (
            "bedrock_transcribe"
            if self.backend == "transcribe"
            else "bedrock_nova_sonic"
        )
        self.model_id = (
            "amazon.transcribe"
            if self.backend == "transcribe"
            else os.environ.get(
                "BEDROCK_NOVA_SONIC_MODEL_ID", "amazon.nova-sonic-v1:0"
            )
        )

    def invoke(self, req: AsrRequest) -> AsrResponse:
        if self.backend == "transcribe":
            return self._invoke_transcribe(req)
        # nova_sonic は P5+ で実装。現状は明示的に not_implemented を返す。
        raise EngineError(
            "not_implemented",
            "Bedrock Nova Sonic backend is not implemented yet",
            provider_detail={"region": self.region, "model_id": self.model_id},
        )

    # ------------------------------------------------------------------
    # Transcribe Streaming (sync wrapper)
    # ------------------------------------------------------------------
    def _invoke_transcribe(self, req: AsrRequest) -> AsrResponse:
        if not req.mime_type.startswith(_PCM_MIME_PREFIX):
            raise EngineError(
                "invalid_request",
                "Bedrock Transcribe backend requires audio/pcm (16kHz mono int16 LE)",
                provider_detail={"mime_type": req.mime_type},
            )
        sample_rate = _extract_sample_rate(req.mime_type) or 16000

        audio_bytes = decode_audio_b64(req.audio_b64)

        try:
            from amazon_transcribe.client import TranscribeStreamingClient
            from amazon_transcribe.handlers import TranscriptResultStreamHandler
            from amazon_transcribe.model import TranscriptEvent
        except ImportError as exc:
            raise EngineError(
                "config_missing",
                "amazon-transcribe SDK is not installed. add 'amazon-transcribe' to requirements.txt",
            ) from exc

        start = time.monotonic()
        language = req.language or "ja-JP"

        class _Handler(TranscriptResultStreamHandler):
            def __init__(self, stream):
                super().__init__(stream)
                self.segments: list[AsrSegment] = []
                self.text_parts: list[str] = []

            async def handle_transcript_event(
                self, transcript_event: TranscriptEvent
            ) -> None:
                for result in transcript_event.transcript.results:
                    if result.is_partial:
                        continue
                    for alt in result.alternatives:
                        if not alt.transcript:
                            continue
                        self.text_parts.append(alt.transcript)
                        self.segments.append(
                            AsrSegment(
                                start_ms=int((result.start_time or 0.0) * 1000),
                                end_ms=int((result.end_time or 0.0) * 1000),
                                text=alt.transcript,
                            )
                        )

        async def _drive() -> tuple[str, list[AsrSegment]]:
            client = TranscribeStreamingClient(region=self.region)
            stream = await client.start_stream_transcription(
                language_code=language,
                media_sample_rate_hz=sample_rate,
                media_encoding="pcm",
            )

            async def _send():
                chunk_size = sample_rate * 2  # int16 → 1 秒分
                for i in range(0, len(audio_bytes), chunk_size):
                    chunk = audio_bytes[i : i + chunk_size]
                    await stream.input_stream.send_audio_event(audio_chunk=chunk)
                await stream.input_stream.end_stream()

            handler = _Handler(stream.output_stream)
            await asyncio.gather(_send(), handler.handle_events())
            return " ".join(handler.text_parts).strip(), handler.segments

        try:
            text, segments = asyncio.run(_drive())
        except EngineError:
            raise
        except Exception as exc:  # noqa: BLE001
            raise EngineError(
                "provider_error",
                f"transcribe streaming failed: {exc}",
                retryable=True,
            ) from exc

        return AsrResponse(
            engine=self.name,
            text=text,
            segments=segments,
            metadata=build_metadata(
                model_id=self.model_id,
                start_monotonic=start,
                request_id=req.request_id,
                extra={
                    "region": self.region,
                    "language": language,
                    "sample_rate": sample_rate,
                },
            ),
        )


def _extract_sample_rate(mime_type: str) -> int | None:
    if not mime_type or "rate=" not in mime_type:
        return None
    try:
        return int(mime_type.split("rate=")[1].split(";")[0].strip())
    except (ValueError, IndexError):
        return None
