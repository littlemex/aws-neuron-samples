"""Bedrock-team TTS engine: Amazon Polly wrapper.

Bedrock's text-to-speech story is currently provided by Polly (Nova Sonic
is bidirectional-stream-only and not usable from the simple InvokeModel
flow we want here). We therefore wrap Polly under the same TtsEngine
contract so the operator picks "bedrock_polly_*" the same way they'd pick
any other engine in the slot.

Configuration:
  POLLY_REGION             必須 (deploy-defaults.env に集約)
  POLLY_OUTPUT_FORMAT      default "mp3"
  POLLY_SAMPLE_RATE        default "24000" (24kHz neural is the recommended pair)

Engine factories in __init__.py expose pre-configured voice/engine pairs
(e.g. bedrock_polly_tomoko_neural). Each factory just instantiates this
class with different defaults; per-call overrides via TtsOptions still
apply on top.
"""
from __future__ import annotations

import base64
import os
import time
from typing import Optional

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from contracts import EngineError, TtsRequest, TtsResponse
from engines._common import build_metadata, env_required
from engines.tts.base import TtsEngine


_DEFAULT_OUTPUT_FORMAT = "mp3"
_DEFAULT_SAMPLE_RATE = "24000"


class PollyTtsEngine(TtsEngine):
    """Polly SynthesizeSpeech wrapper.

    The instance is constructed with default voice / engine values; callers
    can override per-request via ``TtsRequest.options``.
    """

    name = "bedrock_polly"

    def __init__(
        self,
        voice: str = "Tomoko",
        polly_engine: str = "neural",
        language_code: str = "ja-JP",
        region: Optional[str] = None,
        engine_name: Optional[str] = None,
    ) -> None:
        # Polly is its own AWS service (not Bedrock), but we treat it as the
        # "Bedrock-team cloud TTS" because it lives in the same account /
        # ecosystem and uses the same IAM role wiring as the rest of the
        # Bedrock engines in this project.
        # POLLY_REGION は deploy.sh / deploy-defaults.env が必ず注入する
        # 必須 env (旧 us-east-1 default は撤廃)。Polly Neural の GA 状況は
        # リージョンによって違うため、デプロイ先と分離して持てる。
        self.region = region or env_required("POLLY_REGION")
        self.voice = voice
        self.polly_engine = polly_engine  # "neural" | "standard" | "long-form"
        self.language_code = language_code
        self.model_id = f"polly:{voice}/{polly_engine}"
        if engine_name:
            self.name = engine_name
        self._client = boto3.client("polly", region_name=self.region)

    def synthesize(self, req: TtsRequest) -> TtsResponse:
        start = time.monotonic()
        opts = req.options
        voice = opts.voice or self.voice
        polly_engine = self.polly_engine
        # speed 1.0 = no SSML; a value != 1.0 wraps the text in <prosody rate=...>.
        # Polly's <prosody rate> accepts percent strings ("90%", "120%").
        if opts.speed and abs(opts.speed - 1.0) > 1e-6:
            pct = max(20, min(200, int(round(opts.speed * 100))))
            text = (
                f"<speak><prosody rate=\"{pct}%\">"
                f"{_xml_escape(req.text)}</prosody></speak>"
            )
            text_type = "ssml"
        else:
            text = req.text
            text_type = "text"

        output_format = (
            opts.audio_format
            or os.environ.get("POLLY_OUTPUT_FORMAT")
            or _DEFAULT_OUTPUT_FORMAT
        )
        sample_rate = os.environ.get("POLLY_SAMPLE_RATE", _DEFAULT_SAMPLE_RATE)
        language_code = opts.language or self.language_code

        try:
            resp = self._client.synthesize_speech(
                Engine=polly_engine,
                OutputFormat=output_format,
                Text=text,
                TextType=text_type,
                VoiceId=voice,
                LanguageCode=language_code,
                SampleRate=sample_rate,
            )
        except (ClientError, BotoCoreError) as exc:
            raise EngineError(
                "provider_error",
                f"polly synthesize_speech failed: {exc}",
                retryable=True,
            ) from exc

        try:
            audio_bytes = resp["AudioStream"].read()
        except KeyError as exc:
            raise EngineError(
                "provider_invalid_response",
                f"polly response missing AudioStream: {exc}",
            ) from exc

        return TtsResponse(
            engine=self.name,
            audio_b64=base64.b64encode(audio_bytes).decode("ascii"),
            audio_format=output_format,
            metadata=build_metadata(
                model_id=self.model_id,
                start_monotonic=start,
                request_id=req.request_id,
                extra={
                    "polly_region": self.region,
                    "voice": voice,
                    "polly_engine": polly_engine,
                    "language": language_code,
                    "sample_rate": sample_rate,
                    "audio_bytes": len(audio_bytes),
                },
            ),
        )


def _xml_escape(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )
