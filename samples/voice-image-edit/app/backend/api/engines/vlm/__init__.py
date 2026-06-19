"""VLM スロットの registry。

Bedrock 系 factory はモデル ID の Python literal を持たない。値は必ず
deploy.sh / deploy-defaults.env が注入する env を読み、未設定なら起動時に
EngineError("config_missing") を出して fail-fast する。
"""
from __future__ import annotations

import os
from typing import Callable

from contracts import EngineError
from engines._common import env_required
from engines.vlm.base import VlmEngine
from engines.vlm.bedrock import BedrockVlmEngine
from engines.vlm.trainium import TrainiumVlmEngine


def _bedrock_claude_opus() -> VlmEngine:
    # Claude Opus 4.x is served only via a cross-region inference profile
    # (us.anthropic.claude-opus-4-5-...), so the model id here is a profile id,
    # not a bare foundation-model id, and the instance role must allow the
    # bedrock inference-profile ARNs (see ApiInstanceRolePolicy). Replaces the
    # retired claude-3-5-sonnet which reached end-of-life on Bedrock.
    return BedrockVlmEngine(
        model_id=env_required("BEDROCK_CLAUDE_OPUS_MODEL_ID"),
        engine_name="bedrock_claude_opus",
    )


# NOTE: the VLM slot intentionally exposes ONLY two engines — the self-hosted
# Trainium Qwen3-VL (the headline path) and a single managed Bedrock fallback
# (Claude Opus). The Nova Pro / Nova Lite VLM engines were removed: a second
# Bedrock VLM only widened the surface for review/instruction failures without
# adding demo value, so we consolidated to one. (Nova Canvas lives in the EDIT
# slot and Nova Sonic in the ASR slot — those are unrelated and stay.)
ENGINES: dict[str, Callable[[], VlmEngine]] = {
    "bedrock_claude_opus": _bedrock_claude_opus,
    "trainium": TrainiumVlmEngine,
}

DEFAULT_ENV_VAR = "VLM_ENGINE_DEFAULT"
# Last-resort fallback when VLM_ENGINE_DEFAULT is unset. Points at the managed
# Bedrock engine (not trainium) to match the other slots' convention: the
# self-hosted engine needs TRAINIUM_VLM_URL which may be absent, whereas the
# Bedrock engine works as long as the account has model access.
DEFAULT_FALLBACK = "bedrock_claude_opus"

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
