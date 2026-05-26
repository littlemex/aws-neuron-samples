"""VLM スロットの registry。"""
from __future__ import annotations

import os
from typing import Callable

from contracts import EngineError
from engines.vlm.base import VlmEngine
from engines.vlm.bedrock import BedrockVlmEngine
from engines.vlm.trainium import TrainiumVlmEngine


def _bedrock_claude_sonnet() -> VlmEngine:
    return BedrockVlmEngine(
        model_id=os.environ.get(
            "BEDROCK_CLAUDE_SONNET_MODEL_ID",
            "anthropic.claude-3-5-sonnet-20241022-v2:0",
        ),
        engine_name="bedrock_claude_sonnet",
    )


def _bedrock_nova_pro() -> VlmEngine:
    return BedrockVlmEngine(
        model_id=os.environ.get("BEDROCK_NOVA_PRO_MODEL_ID", "amazon.nova-pro-v1:0"),
        engine_name="bedrock_nova_pro",
    )


def _bedrock_nova_lite() -> VlmEngine:
    return BedrockVlmEngine(
        model_id=os.environ.get("BEDROCK_NOVA_LITE_MODEL_ID", "amazon.nova-lite-v1:0"),
        engine_name="bedrock_nova_lite",
    )


ENGINES: dict[str, Callable[[], VlmEngine]] = {
    "bedrock_claude_sonnet": _bedrock_claude_sonnet,
    "bedrock_nova_pro": _bedrock_nova_pro,
    "bedrock_nova_lite": _bedrock_nova_lite,
    "trainium": TrainiumVlmEngine,
}

DEFAULT_ENV_VAR = "VLM_ENGINE_DEFAULT"
DEFAULT_FALLBACK = "bedrock_nova_lite"

_cache: dict[str, VlmEngine] = {}


def list_engines() -> list[str]:
    return sorted(ENGINES.keys())


def get_engine(name: str | None = None) -> VlmEngine:
    resolved = name or os.environ.get(DEFAULT_ENV_VAR) or DEFAULT_FALLBACK
    if resolved not in ENGINES:
        raise EngineError(
            "unknown_engine",
            f"vlm engine '{resolved}' is not registered",
            provider_detail={"available": list_engines()},
        )
    if resolved not in _cache:
        _cache[resolved] = ENGINES[resolved]()
    return _cache[resolved]


__all__ = [
    "VlmEngine",
    "ENGINES",
    "DEFAULT_ENV_VAR",
    "DEFAULT_FALLBACK",
    "get_engine",
    "list_engines",
]
