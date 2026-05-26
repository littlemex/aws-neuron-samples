"""ImageEditEngine の抽象基底。

すべてのエンジンは EditRequest を受け取り EditResponse を返す。
失敗は EngineError を raise する。エンジンは UI / Lambda の知識を持たない。
"""
from __future__ import annotations

from abc import ABC, abstractmethod

from contracts import EditRequest, EditResponse


class ImageEditEngine(ABC):
    name: str = "base"
    model_id: str = "unknown"

    @abstractmethod
    def invoke(self, req: EditRequest) -> EditResponse:
        """画像編集を実行して結果を返す。失敗時は EngineError を raise する。"""

    def health(self) -> dict:
        return {"name": self.name, "model_id": self.model_id, "status": "unknown"}
