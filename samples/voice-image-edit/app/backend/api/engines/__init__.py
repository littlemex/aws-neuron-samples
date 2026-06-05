"""5 slot (ASR / VLM / EDIT / GENERATE / TTS) unified registry.

The UI and the API route handlers go through this module to reach a slot's
sub-registry. To add a new engine, append one line to the matching slot
sub-module's ``ENGINES`` dict — this file is just a thin aggregator.
"""
from __future__ import annotations

from typing import Any

from contracts import EngineError
from engines import asr as _asr
from engines import edit as _edit
from engines import generate as _generate
from engines import tts as _tts
from engines import vlm as _vlm

# slot name -> sub-module
_SLOTS: dict[str, Any] = {
    "asr": _asr,
    "vlm": _vlm,
    "edit": _edit,
    "generate": _generate,
    "tts": _tts,
}


def list_slots() -> list[str]:
    return ["asr", "vlm", "edit", "generate", "tts"]


def list_engines(slot: str) -> list[str]:
    if slot not in _SLOTS:
        raise EngineError("unknown_slot", f"unknown slot: {slot}")
    return _SLOTS[slot].list_engines()


def get_engine(slot: str, name: str | None = None):
    if slot not in _SLOTS:
        raise EngineError("unknown_slot", f"unknown slot: {slot}")
    return _SLOTS[slot].get_engine(name)


def default_engine(slot: str) -> str:
    if slot not in _SLOTS:
        raise EngineError("unknown_slot", f"unknown slot: {slot}")
    import os

    return (
        os.environ.get(_SLOTS[slot].DEFAULT_ENV_VAR)
        or _SLOTS[slot].DEFAULT_FALLBACK
    )


def list_all() -> dict[str, dict[str, Any]]:
    """全スロット ✕ 実装の組み合わせを 1 度に返す (UI 設定画面向け)。"""
    return {
        slot: {
            "engines": _SLOTS[slot].list_engines(),
            "default": default_engine(slot),
        }
        for slot in list_slots()
    }


__all__ = [
    "list_slots",
    "list_engines",
    "get_engine",
    "default_engine",
    "list_all",
]
