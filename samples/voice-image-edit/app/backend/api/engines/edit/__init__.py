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
from engines.edit.bedrock import (
    NovaCanvasEditEngine,
    StabilitySd35EditEngine,
)
from engines.edit.dummy import DummyEditEngine
from engines.edit.trainium import TrainiumEditEngine


def _bedrock_nova_canvas() -> ImageEditEngine:
    # model_id / region resolution はクラス側 (NovaCanvasEditEngine._resolve_*)
    # に集約。ここで Python literal を持つと「task JSON に入っていない値が
    # サイレントで動く」二重管理になるので、registry は engine_name だけ渡す
    # 薄い factory に保つ。
    return NovaCanvasEditEngine(engine_name="bedrock_nova_canvas")


def _bedrock_stability_sd35() -> ImageEditEngine:
    # Region and model id are resolved inside the class so the registry
    # stays a thin one-liner. SD 3.5 lives in us-west-2; the class does
    # NOT fall back to BEDROCK_REGION (us-east-1) on purpose.
    return StabilitySd35EditEngine(engine_name="bedrock_stability_sd35")


ENGINES: dict[str, Callable[[], ImageEditEngine]] = {
    "dummy": DummyEditEngine,
    "bedrock_nova_canvas": _bedrock_nova_canvas,
    "bedrock_stability_sd35": _bedrock_stability_sd35,
    "trainium": TrainiumEditEngine,
}

DEFAULT_ENV_VAR = "EDIT_ENGINE_DEFAULT"
# Stability SD 3.5 is the only ACTIVE Bedrock image-to-image SKU today; pick
# it as the fallback so a fresh deploy does not silently land on the LEGACY
# Nova Canvas. Operators can still flip back via env or /manage.
DEFAULT_FALLBACK = "bedrock_stability_sd35"

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
