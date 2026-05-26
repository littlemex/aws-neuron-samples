"""VlmEngine 抽象基底。"""
from __future__ import annotations

from abc import ABC, abstractmethod

from contracts import VlmRequest, VlmResponse


class VlmEngine(ABC):
    name: str = "base"
    model_id: str = "unknown"

    @abstractmethod
    def invoke(self, req: VlmRequest) -> VlmResponse:
        """指示モード or レビューモードで VLM を呼ぶ。失敗時は EngineError を raise。"""

    def health(self) -> dict:
        return {"name": self.name, "model_id": self.model_id, "status": "unknown"}
