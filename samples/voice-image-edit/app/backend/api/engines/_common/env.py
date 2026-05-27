"""環境変数読み出しの薄いラッパ。

ハードコード禁止 (CLAUDE.md) を守るため、エンジンが要求する設定は必ずここを通す。
未設定や不正値は EngineError("config_missing", ...) に正規化する。
"""
from __future__ import annotations

import os
from typing import Iterable

from contracts import EngineError


def env_required(*names: str, hint: str | None = None) -> str:
    """``names`` のいずれか先頭 1 つでも値を持っていればそれを返す。

    fallback chain (例: ``TRAINIUM_EDIT_URL`` → ``TRAINIUM_BACKEND_URL``) を 1 行で書ける。
    全部未設定なら ``config_missing`` で raise。
    """
    for name in names:
        v = os.environ.get(name)
        if v:
            return v
    label = " / ".join(names)
    msg = f"{label} env var is required"
    if hint:
        msg = f"{msg} ({hint})"
    raise EngineError("config_missing", msg)


def env_float(name: str, default: float, *, fallback: Iterable[str] = ()) -> float:
    """``name`` (なければ ``fallback``) を float で読む。値が無ければ ``default``。

    int リテラル ("60") も許す。invalid な文字列は ``config_missing``。
    """
    raw = os.environ.get(name)
    if raw is None:
        for f in fallback:
            v = os.environ.get(f)
            if v is not None:
                raw = v
                break
    if raw is None or raw == "":
        return default
    try:
        return float(raw)
    except (TypeError, ValueError) as exc:
        raise EngineError(
            "config_missing",
            f"{name} must be a number, got: {raw!r}",
        ) from exc


def env_int(name: str, default: int, *, fallback: Iterable[str] = ()) -> int:
    raw = os.environ.get(name)
    if raw is None:
        for f in fallback:
            v = os.environ.get(f)
            if v is not None:
                raw = v
                break
    if raw is None or raw == "":
        return default
    try:
        return int(raw)
    except (TypeError, ValueError) as exc:
        raise EngineError(
            "config_missing",
            f"{name} must be an integer, got: {raw!r}",
        ) from exc
