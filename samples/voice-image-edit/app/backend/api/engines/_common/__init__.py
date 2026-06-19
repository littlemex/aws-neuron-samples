"""Shared helpers for ASR/VLM/EDIT engines.

設計方針:
  - contracts.py の Request/Response を変えずに、Bedrock 系と Trainium 系で重複する
    「環境変数読み出し」「base64 decode」「HTTP status → EngineError」「メタデータ組み立て」
    を 1 箇所に寄せる。
  - 既存の test_engines.py が期待する例外コード (config_missing / invalid_request /
    provider_error / provider_invalid_response) と retryable フラグを 100% 維持する。
  - ヘルパー単体でも mock しやすいよう、副作用は env / clock のみに局限する。
"""
from __future__ import annotations

from .env import env_required, env_float, env_int
from .decode import (
    decode_image_b64,
    decode_audio_b64,
    guess_image_mime,
    guess_image_format,
    downscale_image_for_vlm,
)
from .http import raise_for_status, safe_decode
from .lang import whisper_language
from .meta import build_metadata
from .text import strip_thinking

__all__ = [
    "env_required",
    "env_float",
    "env_int",
    "decode_image_b64",
    "decode_audio_b64",
    "guess_image_mime",
    "guess_image_format",
    "downscale_image_for_vlm",
    "raise_for_status",
    "safe_decode",
    "whisper_language",
    "build_metadata",
    "strip_thinking",
]
