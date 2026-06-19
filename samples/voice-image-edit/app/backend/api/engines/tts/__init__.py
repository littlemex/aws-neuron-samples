"""TTS slot registry.

Add a new engine by appending one factory line to ``ENGINES``. Factories
take zero arguments and return a ``TtsEngine`` instance.
"""
from __future__ import annotations

import os
from typing import Callable

from contracts import EngineError
from engines.tts.base import TtsEngine
from engines.tts.bedrock import PollyTtsEngine
from engines.tts.dummy import DummyTtsEngine
from engines.tts.trainium import TrainiumTtsEngine


def _polly_tomoko_neural() -> TtsEngine:
    return PollyTtsEngine(
        voice="Tomoko",
        polly_engine="neural",
        language_code="ja-JP",
        engine_name="bedrock_polly_tomoko_neural",
    )


def _polly_kazuha_neural() -> TtsEngine:
    return PollyTtsEngine(
        voice="Kazuha",
        polly_engine="neural",
        language_code="ja-JP",
        engine_name="bedrock_polly_kazuha_neural",
    )


def _polly_takumi_neural() -> TtsEngine:
    return PollyTtsEngine(
        voice="Takumi",
        polly_engine="neural",
        language_code="ja-JP",
        engine_name="bedrock_polly_takumi_neural",
    )


def _polly_mizuki_standard() -> TtsEngine:
    return PollyTtsEngine(
        voice="Mizuki",
        polly_engine="standard",
        language_code="ja-JP",
        engine_name="bedrock_polly_mizuki_standard",
    )


ENGINES: dict[str, Callable[[], TtsEngine]] = {
    "dummy": DummyTtsEngine,
    "bedrock_polly_tomoko_neural": _polly_tomoko_neural,
    "bedrock_polly_kazuha_neural": _polly_kazuha_neural,
    "bedrock_polly_takumi_neural": _polly_takumi_neural,
    "bedrock_polly_mizuki_standard": _polly_mizuki_standard,
    "trainium": TrainiumTtsEngine,
}

DEFAULT_ENV_VAR = "TTS_ENGINE_DEFAULT"
# This is a Trainium demo, so the self-hosted TTS (XTTS / F5-TTS) is the
# headline default — matching ASR / VLM / EDIT. Operators can flip to a
# managed Polly voice via /manage UI, env override, or per-request engine
# field (bedrock_polly_tomoko_neural etc. remain registered).
DEFAULT_FALLBACK = "trainium"

_cache: dict[str, TtsEngine] = {}


def list_engines() -> list[str]:
    return sorted(ENGINES.keys())


def get_engine(name: str | None = None) -> TtsEngine:
    resolved = name or os.environ.get(DEFAULT_ENV_VAR) or DEFAULT_FALLBACK
    if resolved not in ENGINES:
        raise EngineError(
            "unknown_engine",
            f"tts engine '{resolved}' is not registered",
            provider_detail={"available": list_engines()},
        )
    if resolved not in _cache:
        _cache[resolved] = ENGINES[resolved]()
    return _cache[resolved]


__all__ = [
    "TtsEngine",
    "ENGINES",
    "DEFAULT_ENV_VAR",
    "DEFAULT_FALLBACK",
    "get_engine",
    "list_engines",
]
