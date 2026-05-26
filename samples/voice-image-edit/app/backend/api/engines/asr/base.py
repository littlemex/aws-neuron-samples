"""AsrEngine 抽象基底。"""
from __future__ import annotations

from abc import ABC, abstractmethod

from contracts import AsrRequest, AsrResponse


class AsrEngine(ABC):
    name: str = "base"
    model_id: str = "unknown"

    @abstractmethod
    def invoke(self, req: AsrRequest) -> AsrResponse:
        """音声 → テキスト指示。失敗時は EngineError を raise する。"""

    def health(self) -> dict:
        return {"name": self.name, "model_id": self.model_id, "status": "unknown"}
