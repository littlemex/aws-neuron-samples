"""TtsEngine abstract base.

Every TTS engine takes a TtsRequest and returns a TtsResponse. Failures
must raise EngineError. Engines have no knowledge of UI / Lambda / S3 —
the caller layer (api/app.py) handles presigning and HTTP framing.
"""
from __future__ import annotations

from abc import ABC, abstractmethod

from contracts import TtsRequest, TtsResponse


class TtsEngine(ABC):
    name: str = "base"
    model_id: str = "unknown"

    @abstractmethod
    def synthesize(self, req: TtsRequest) -> TtsResponse:
        """Synthesize speech from text. Raise EngineError on failure."""

    def health(self) -> dict:
        return {"name": self.name, "model_id": self.model_id, "status": "unknown"}
