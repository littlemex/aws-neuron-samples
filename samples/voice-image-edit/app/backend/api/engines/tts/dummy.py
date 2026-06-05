"""Dummy TTS engine: emits a tiny silent MP3 so the UI / E2E plumbing can
exercise the slot without IAM / network access. The bytes here are a
hand-crafted 0.1s 44.1kHz silent MP3 frame; just enough that the browser
<audio> element accepts it as a real audio resource.
"""
from __future__ import annotations

import base64
import time

from contracts import TtsRequest, TtsResponse
from engines._common import build_metadata
from engines.tts.base import TtsEngine


# 26-byte ID3v2 header + a single MPEG-1 Layer III silent frame (104B). Not
# meant for human consumption; just enough to round-trip through any audio
# decoder that recognises MP3.
_SILENT_MP3_BYTES = (
    b"ID3\x04\x00\x00\x00\x00\x00\x00"
    b"\xff\xfb\x90\x64" + b"\x00" * 100
)


class DummyTtsEngine(TtsEngine):
    name = "dummy"
    model_id = "dummy/silent-mp3-v1"

    def synthesize(self, req: TtsRequest) -> TtsResponse:
        start = time.monotonic()
        return TtsResponse(
            engine=self.name,
            audio_b64=base64.b64encode(_SILENT_MP3_BYTES).decode("ascii"),
            audio_format="mp3",
            metadata=build_metadata(
                model_id=self.model_id,
                start_monotonic=start,
                request_id=req.request_id,
                extra={"audio_bytes": len(_SILENT_MP3_BYTES)},
            ),
        )
