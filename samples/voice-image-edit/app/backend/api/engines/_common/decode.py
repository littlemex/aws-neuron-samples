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


# The Neuron Qwen3-VL vision encoder is compiled with a fixed maximum image
# patch bucket (16384 raw 14x14 patches ~= a 1792x1792 image). An image larger
# than that makes the model runner raise
#   AssertionError: Total number of image patches N exceeds largest bucket (16384)
# which kills the whole vLLM EngineCore (and then systemd restart-loops it,
# recompiling each time). Bedrock has its own size limits too. So before we
# ever hand an image to a VLM we downscale its longest side to a safe bound.
# 1568px -> (1568/14)^2 = 12544 patches, comfortably under 16384 with margin
# for non-square aspect ratios. Downscaling only; small images pass untouched.
_VLM_MAX_IMAGE_LONG_SIDE = 1568


def downscale_image_for_vlm(
    image_bytes: bytes, *, max_long_side: int = _VLM_MAX_IMAGE_LONG_SIDE
) -> bytes:
    """Return ``image_bytes`` resized so its longest side <= ``max_long_side``.

    Returns the input unchanged when it is already small enough or when Pillow
    is unavailable / the bytes cannot be parsed (we must never turn a working
    request into a hard failure just because resizing was not possible — the
    engine-side handling still applies).
    """
    try:
        import io

        from PIL import Image
    except Exception:
        return image_bytes

    try:
        with Image.open(io.BytesIO(image_bytes)) as im:
            w, h = im.size
            longest = max(w, h)
            if longest <= max_long_side:
                return image_bytes
            scale = max_long_side / float(longest)
            new_size = (max(1, round(w * scale)), max(1, round(h * scale)))
            fmt = im.format or "PNG"
            # Drop alpha for JPEG; keep mode otherwise.
            resized = im.resize(new_size, Image.LANCZOS)
            buf = io.BytesIO()
            if fmt.upper() in ("JPG", "JPEG") and resized.mode not in ("RGB", "L"):
                resized = resized.convert("RGB")
            resized.save(buf, format=fmt)
            return buf.getvalue()
    except Exception:
        # Parsing/resizing failed — return original; the engine may still cope
        # (or fail with its own clear error) rather than us masking the problem.
        return image_bytes
