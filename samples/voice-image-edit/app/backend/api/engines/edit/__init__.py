"""EDIT スロットの registry。

新しい実装を増やす時は、本ファイルの `ENGINES` に
`"<name>": <factory>` を 1 行追加するだけ。
factory は引数 0 個で `ImageEditEngine` を返す callable。
"""
from __future__ import annotations

import os
from typing import Callable

from contracts import EngineError
from engines.edit.base import ImageEditEngine
from engines.edit.bedrock import BedrockEditEngine
from engines.edit.dummy import DummyEditEngine
from engines.edit.trainium import TrainiumEditEngine


def _bedrock_nova_canvas() -> ImageEditEngine:
    return BedrockEditEngine(
        model_id=os.environ.get(
            "BEDROCK_NOVA_CANVAS_MODEL_ID", "amazon.nova-canvas-v1:0"
        ),
        engine_name="bedrock_nova_canvas",
    )


ENGINES: dict[str, Callable[[], ImageEditEngine]] = {
    "dummy": DummyEditEngine,
    "bedrock_nova_canvas": _bedrock_nova_canvas,
    "trainium": TrainiumEditEngine,
}

DEFAULT_ENV_VAR = "EDIT_ENGINE_DEFAULT"
DEFAULT_FALLBACK = "dummy"

_cache: dict[str, ImageEditEngine] = {}


def list_engines() -> list[str]:
    return sorted(ENGINES.keys())


def get_engine(name: str | None = None) -> ImageEditEngine:
    resolved = name or os.environ.get(DEFAULT_ENV_VAR) or DEFAULT_FALLBACK
    if resolved not in ENGINES:
        raise EngineError(
            "unknown_engine",
            f"edit engine '{resolved}' is not registered",
            provider_detail={"available": list_engines()},
        )
    if resolved not in _cache:
        _cache[resolved] = ENGINES[resolved]()
    return _cache[resolved]


__all__ = [
    "ImageEditEngine",
    "ENGINES",
    "DEFAULT_ENV_VAR",
    "DEFAULT_FALLBACK",
    "get_engine",
    "list_engines",
]
