"""image/audio base64 デコードと MIME 推定。

base64 / 空 bytes は invalid_request。MIME 判定は magic bytes ベース。
"""
from __future__ import annotations

import base64

from contracts import EngineError


def decode_image_b64(image_b64: str) -> bytes:
    """``image_b64`` を bytes に decode。invalid なら EngineError("invalid_request")."""
    try:
        image_bytes = base64.b64decode(image_b64, validate=True)
    except (ValueError, TypeError) as exc:
        raise EngineError(
            "invalid_request", f"image_b64 is not valid base64: {exc}"
        ) from exc
    if not image_bytes:
        raise EngineError("invalid_request", "image_b64 decoded to empty bytes")
    return image_bytes


def decode_audio_b64(audio_b64: str, *, allow_empty: bool = False) -> bytes:
    try:
        audio_bytes = base64.b64decode(audio_b64, validate=True)
    except (ValueError, TypeError) as exc:
        raise EngineError(
            "invalid_request", f"audio_b64 is not valid base64: {exc}"
        ) from exc
    if not audio_bytes and not allow_empty:
        raise EngineError("invalid_request", "audio_b64 decoded to empty bytes")
    return audio_bytes


def guess_image_mime(image_bytes: bytes) -> str:
    """MIME (``image/png`` 等) を返す。"""
    if image_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if image_bytes.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if image_bytes.startswith(b"GIF87a") or image_bytes.startswith(b"GIF89a"):
        return "image/gif"
    if image_bytes[:4] == b"RIFF" and image_bytes[8:12] == b"WEBP":
        return "image/webp"
    return "image/png"


def guess_image_format(image_bytes: bytes) -> str:
    """Bedrock Converse API が受ける format string (``png`` 等) を返す。"""
    return guess_image_mime(image_bytes).split("/", 1)[1]
