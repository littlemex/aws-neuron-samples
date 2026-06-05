"""ImageGenerateEngine abstract base.

Every engine accepts a ``GenerateRequest`` and returns a
``GenerateResponse``. Failures must raise ``EngineError``. Engines have
no knowledge of UI / Lambda / S3. The only difference from
``ImageEditEngine`` is that no input image is taken — the prompt alone
drives synthesis.
"""
from __future__ import annotations

from abc import ABC, abstractmethod

from contracts import GenerateRequest, GenerateResponse


class ImageGenerateEngine(ABC):
    name: str = "base"
    model_id: str = "unknown"

    @abstractmethod
    def invoke(self, req: GenerateRequest) -> GenerateResponse:
        """Synthesize an image from text. Raise EngineError on failure."""

    def health(self) -> dict:
        return {"name": self.name, "model_id": self.model_id, "status": "unknown"}
