"""3 スロット (ASR / VLM / EDIT) 統合 registry。

UI / Lambda は本モジュール経由でスロット別の registry にアクセスする。
新しい実装を追加する時は、対応する slot サブモジュールの ENGINES に
1 行加えるだけ。本モジュールはエクスポート集約だけで状態を持たない。
"""
from __future__ import annotations

from typing import Any

from contracts import EngineError
from engines import asr as _asr
from engines import edit as _edit
from engines import vlm as _vlm

# slot 名 → サブモジュール
_SLOTS: dict[str, Any] = {
    "asr": _asr,
    "vlm": _vlm,
    "edit": _edit,
}


def list_slots() -> list[str]:
    return ["asr", "vlm", "edit"]


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
