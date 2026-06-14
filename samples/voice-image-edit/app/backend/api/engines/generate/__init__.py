"""GENERATE slot registry.

Add a new engine by appending one factory line to ``ENGINES``. Factories
take zero arguments and return an ``ImageGenerateEngine`` instance.

Stability の Bedrock モデル ID は Stability 側の SKU と 1:1 に紐づいた
半固定値なので Python 側に default を残す。値を絞ったり差し替えたい場合は
BEDROCK_STABILITY_*_MODEL_ID env を deploy.sh で指定する。
"""
from __future__ import annotations

import os
from typing import Callable

from contracts import EngineError
from engines.generate.base import ImageGenerateEngine
from engines.generate.bedrock import StabilityBedrockGenerateEngine
from engines.generate.dummy import DummyGenerateEngine


def _bedrock_stability_ultra() -> ImageGenerateEngine:
    return StabilityBedrockGenerateEngine(
        model_id=os.environ.get("BEDROCK_STABILITY_ULTRA_MODEL_ID") or "stability.stable-image-ultra-v1:1",
        engine_name="bedrock_stability_ultra",
    )


def _bedrock_stability_core() -> ImageGenerateEngine:
    return StabilityBedrockGenerateEngine(
        model_id=os.environ.get("BEDROCK_STABILITY_CORE_MODEL_ID") or "stability.stable-image-core-v1:1",
        engine_name="bedrock_stability_core",
    )


def _bedrock_stability_sd35() -> ImageGenerateEngine:
    return StabilityBedrockGenerateEngine(
        model_id=os.environ.get("BEDROCK_STABILITY_SD35_MODEL_ID") or "stability.sd3-5-large-v1:0",
        engine_name="bedrock_stability_sd35",
    )


ENGINES: dict[str, Callable[[], ImageGenerateEngine]] = {
    "dummy": DummyGenerateEngine,
    "bedrock_stability_ultra": _bedrock_stability_ultra,
    "bedrock_stability_core": _bedrock_stability_core,
    "bedrock_stability_sd35": _bedrock_stability_sd35,
}

DEFAULT_ENV_VAR = "GENERATE_ENGINE_DEFAULT"
DEFAULT_FALLBACK = "bedrock_stability_ultra"

_cache: dict[str, ImageGenerateEngine] = {}


def list_engines() -> list[str]:
    return sorted(ENGINES.keys())


def get_engine(name: str | None = None) -> ImageGenerateEngine:
    resolved = name or os.environ.get(DEFAULT_ENV_VAR) or DEFAULT_FALLBACK
    if resolved not in ENGINES:
        raise EngineError(
            "unknown_engine",
            f"generate engine '{resolved}' is not registered",
            provider_detail={"available": list_engines()},
        )
    if resolved not in _cache:
        _cache[resolved] = ENGINES[resolved]()
    return _cache[resolved]


__all__ = [
    "ImageGenerateEngine",
    "ENGINES",
    "DEFAULT_ENV_VAR",
    "DEFAULT_FALLBACK",
    "get_engine",
    "list_engines",
]
