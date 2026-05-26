"""ASR スロットの registry。"""
from __future__ import annotations

import os
from typing import Callable

from contracts import EngineError
from engines.asr.base import AsrEngine
from engines.asr.bedrock import BedrockAsrEngine
from engines.asr.trainium import TrainiumAsrEngine


def _bedrock_transcribe() -> AsrEngine:
    return BedrockAsrEngine(backend="transcribe", engine_name="bedrock_transcribe")


def _bedrock_nova_sonic() -> AsrEngine:
    return BedrockAsrEngine(backend="nova_sonic", engine_name="bedrock_nova_sonic")


ENGINES: dict[str, Callable[[], AsrEngine]] = {
    "bedrock_transcribe": _bedrock_transcribe,
    "bedrock_nova_sonic": _bedrock_nova_sonic,
    "trainium": TrainiumAsrEngine,
}

DEFAULT_ENV_VAR = "ASR_ENGINE_DEFAULT"
DEFAULT_FALLBACK = "bedrock_transcribe"

_cache: dict[str, AsrEngine] = {}


def list_engines() -> list[str]:
    return sorted(ENGINES.keys())


def get_engine(name: str | None = None) -> AsrEngine:
    resolved = name or os.environ.get(DEFAULT_ENV_VAR) or DEFAULT_FALLBACK
    if resolved not in ENGINES:
        raise EngineError(
            "unknown_engine",
            f"asr engine '{resolved}' is not registered",
            provider_detail={"available": list_engines()},
        )
    if resolved not in _cache:
        _cache[resolved] = ENGINES[resolved]()
    return _cache[resolved]


__all__ = [
    "AsrEngine",
    "ENGINES",
    "DEFAULT_ENV_VAR",
    "DEFAULT_FALLBACK",
    "get_engine",
    "list_engines",
]
