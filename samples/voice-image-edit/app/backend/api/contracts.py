"""voice-image-edit の 3 スロット (ASR / VLM / EDIT) 共通契約。

UI / Lambda / 各エンジン実装が共有する単一の真実の源。
新しいスロット実装を追加する場合も、ここで定義した
<Slot>Request / <Slot>Response / EngineError の形以外を返してはならない。

設計原則:
  - エンジンは UI / Lambda の知識を持たない。HTTP/JSON は Lambda 層で正規化する。
  - 失敗は EngineError 1 種類だけで表現し、Lambda 層が HTTP status に変換する。
  - 共通 metadata (model_id, latency_ms, request_id, extra) を全スロットで揃える。
"""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from typing import Any, List, Optional


# ---------------------------------------------------------------------------
# 共通: エラー / メタデータ
# ---------------------------------------------------------------------------


class EngineError(Exception):
    """全スロットの全エンジンが投げる唯一のエラー型。

    Lambda 層は code を HTTP status に正規化する。retryable は UI 側の
    リトライ判断に使う (現状は participants と provider_detail で参照のみ)。
    """

    def __init__(
        self,
        code: str,
        message: str,
        retryable: bool = False,
        provider_detail: Optional[dict[str, Any]] = None,
    ):
        super().__init__(message)
        self.code = code
        self.message = message
        self.retryable = retryable
        self.provider_detail = provider_detail or {}

    def to_dict(self) -> dict[str, Any]:
        return {
            "error": {
                "code": self.code,
                "message": self.message,
                "retryable": self.retryable,
                "provider_detail": self.provider_detail,
            }
        }


@dataclass
class EngineMetadata:
    """3 スロット共通の応答メタデータ。"""

    model_id: str
    latency_ms: int
    request_id: Optional[str] = None
    extra: dict[str, Any] = field(default_factory=dict)


# ---------------------------------------------------------------------------
# ASR (音声 → テキスト指示)
# ---------------------------------------------------------------------------


@dataclass
class AsrRequest:
    audio_b64: str
    mime_type: str = "audio/webm"
    language: Optional[str] = None  # "ja", "en" など。None なら自動判定
    engine: Optional[str] = None
    request_id: Optional[str] = None

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "AsrRequest":
        if not isinstance(d, dict):
            raise EngineError("invalid_request", "request body must be JSON object")
        if not d.get("audio_b64"):
            raise EngineError("invalid_request", "audio_b64 is required")
        return cls(
            audio_b64=d["audio_b64"],
            mime_type=d.get("mime_type") or "audio/webm",
            language=d.get("language"),
            engine=d.get("engine"),
            request_id=d.get("request_id"),
        )


@dataclass
class AsrSegment:
    start_ms: int
    end_ms: int
    text: str


@dataclass
class AsrResponse:
    engine: str
    text: str
    metadata: EngineMetadata
    segments: List[AsrSegment] = field(default_factory=list)

    def to_dict(self) -> dict[str, Any]:
        return {
            "engine": self.engine,
            "text": self.text,
            "segments": [asdict(s) for s in self.segments],
            "metadata": asdict(self.metadata),
        }


# ---------------------------------------------------------------------------
# VLM (画像 + テキスト → テキスト)
# ---------------------------------------------------------------------------


@dataclass
class VlmRequest:
    """VLM slot input.

    Three supported modes:
      - "instruction": voice instruction (TEXT ONLY) -> editing prompt for EDIT slot.
                       A pure language transform (JA voice -> EN edit prompt); the
                       BEFORE image is NOT used, so image_b64 is optional/ignored.
      - "review"     : editing instruction + AFTER image -> review comment.
                       image_b64 is REQUIRED (the only image-grounded mode).
      - "translate"  : free-text only (no image) -> English image-generation prompt
                       used by the GENERATE slot to localise non-English input.
    image_b64 is required ONLY for "review"; it is optional for "instruction"
    and ignored for "translate".

    ``language`` selects the response language for the review mode (other modes
    have a fixed response language). Accepted values are short codes such as
    "ja" / "en"; BCP-47 forms ("ja-JP") are collapsed to the base subtag by
    downstream consumers. Engines (bedrock / trainium) read this field via
    ``req.language`` so callers do not need to pass anything for the default
    Japanese review.
    """

    prompt: str
    image_b64: str = ""
    mode: str = "instruction"
    engine: Optional[str] = None
    request_id: Optional[str] = None
    language: Optional[str] = None

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "VlmRequest":
        if not isinstance(d, dict):
            raise EngineError("invalid_request", "request body must be JSON object")
        if not d.get("prompt"):
            raise EngineError("invalid_request", "prompt is required")
        mode = d.get("mode") or "instruction"
        if mode not in {"instruction", "review", "translate"}:
            raise EngineError("invalid_request", f"unknown mode: {mode}")
        image_b64 = d.get("image_b64") or ""
        # Only review is image-grounded. instruction is a text-only language
        # transform now (it used to require the BEFORE image, which was both
        # unnecessary and a crash vector on the Neuron VLM for large images),
        # and translate has always been text-only.
        if mode == "review" and not image_b64:
            raise EngineError(
                "invalid_request", "image_b64 is required for mode=review"
            )
        return cls(
            image_b64=image_b64,
            prompt=d["prompt"],
            mode=mode,
            engine=d.get("engine"),
            request_id=d.get("request_id"),
            language=d.get("language"),
        )


@dataclass
class VlmResponse:
    engine: str
    text: str
    metadata: EngineMetadata

    def to_dict(self) -> dict[str, Any]:
        return {
            "engine": self.engine,
            "text": self.text,
            "metadata": asdict(self.metadata),
        }


# ---------------------------------------------------------------------------
# EDIT (画像 + プロンプト → 編集後画像)
# ---------------------------------------------------------------------------


@dataclass
class EditOptions:
    strength: float = 0.7
    seed: Optional[int] = None
    mask_b64: Optional[str] = None
    negative_prompt: Optional[str] = None

    @classmethod
    def from_dict(cls, d: Optional[dict[str, Any]]) -> "EditOptions":
        if not d:
            return cls()
        return cls(
            strength=float(d.get("strength", 0.7)),
            seed=d.get("seed"),
            mask_b64=d.get("mask_b64"),
            negative_prompt=d.get("negative_prompt"),
        )


@dataclass
class EditRequest:
    image_b64: str
    prompt: str
    engine: Optional[str] = None
    options: EditOptions = field(default_factory=EditOptions)
    request_id: Optional[str] = None

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "EditRequest":
        if not isinstance(d, dict):
            raise EngineError("invalid_request", "request body must be JSON object")
        if not d.get("image_b64"):
            raise EngineError("invalid_request", "image_b64 is required")
        if not d.get("prompt"):
            raise EngineError("invalid_request", "prompt is required")
        return cls(
            image_b64=d["image_b64"],
            prompt=d["prompt"],
            engine=d.get("engine"),
            options=EditOptions.from_dict(d.get("options")),
            request_id=d.get("request_id"),
        )


@dataclass
class EditResponse:
    engine: str
    image_b64: str
    metadata: EngineMetadata

    def to_dict(self) -> dict[str, Any]:
        return {
            "engine": self.engine,
            "image_b64": self.image_b64,
            "metadata": asdict(self.metadata),
        }


# ---------------------------------------------------------------------------
# GENERATE (text -> image)
# ---------------------------------------------------------------------------
# Intentionally symmetrical to the Edit slot, except the input has no image
# so the Options struct is leaner (no strength / mask). The response shape
# is identical to EditResponse (image_b64 + metadata), so the frontend can
# reuse a single display path.


@dataclass
class GenerateOptions:
    seed: Optional[int] = None
    negative_prompt: Optional[str] = None
    aspect_ratio: Optional[str] = None  # e.g. "1:1", "16:9"

    @classmethod
    def from_dict(cls, d: Optional[dict[str, Any]]) -> "GenerateOptions":
        if not d:
            return cls()
        return cls(
            seed=d.get("seed"),
            negative_prompt=d.get("negative_prompt"),
            aspect_ratio=d.get("aspect_ratio"),
        )


@dataclass
class GenerateRequest:
    prompt: str
    engine: Optional[str] = None
    options: GenerateOptions = field(default_factory=GenerateOptions)
    request_id: Optional[str] = None

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "GenerateRequest":
        if not isinstance(d, dict):
            raise EngineError("invalid_request", "request body must be JSON object")
        if not d.get("prompt"):
            raise EngineError("invalid_request", "prompt is required")
        return cls(
            prompt=d["prompt"],
            engine=d.get("engine"),
            options=GenerateOptions.from_dict(d.get("options")),
            request_id=d.get("request_id"),
        )


@dataclass
class GenerateResponse:
    engine: str
    image_b64: str
    metadata: EngineMetadata

    def to_dict(self) -> dict[str, Any]:
        return {
            "engine": self.engine,
            "image_b64": self.image_b64,
            "metadata": asdict(self.metadata),
        }


# ---------------------------------------------------------------------------
# TTS (text -> synthesized speech audio)
# ---------------------------------------------------------------------------
# Optional pipeline stage that reads the VLM review aloud. Cloud (Polly via
# the "bedrock_polly_*" engines) and on-device (Trainium-hosted XTTS / F5-TTS,
# stubbed for now) live behind the same contract.


@dataclass
class TtsOptions:
    voice: Optional[str] = None  # provider-specific voice id (e.g. "Tomoko")
    language: Optional[str] = None  # BCP-47 (e.g. "ja-JP"); None -> engine default
    speed: Optional[float] = None  # 0.5..2.0; None -> engine default
    audio_format: Optional[str] = None  # "mp3" | "ogg_vorbis" | "pcm" -> engine default

    @classmethod
    def from_dict(cls, d: Optional[dict[str, Any]]) -> "TtsOptions":
        if not d:
            return cls()
        speed = d.get("speed")
        return cls(
            voice=d.get("voice"),
            language=d.get("language"),
            speed=float(speed) if speed is not None else None,
            audio_format=d.get("audio_format"),
        )


@dataclass
class TtsRequest:
    text: str
    engine: Optional[str] = None
    options: TtsOptions = field(default_factory=TtsOptions)
    request_id: Optional[str] = None

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "TtsRequest":
        if not isinstance(d, dict):
            raise EngineError("invalid_request", "request body must be JSON object")
        if not d.get("text"):
            raise EngineError("invalid_request", "text is required")
        return cls(
            text=d["text"],
            engine=d.get("engine"),
            options=TtsOptions.from_dict(d.get("options")),
            request_id=d.get("request_id"),
        )


@dataclass
class TtsResponse:
    engine: str
    audio_b64: str  # base64 of the binary audio body
    audio_format: str  # "mp3" / "ogg_vorbis" / "pcm" — matches the bytes above
    metadata: EngineMetadata

    def to_dict(self) -> dict[str, Any]:
        return {
            "engine": self.engine,
            "audio_b64": self.audio_b64,
            "audio_format": self.audio_format,
            "metadata": asdict(self.metadata),
        }


# ---------------------------------------------------------------------------
# 後方互換 alias
# ---------------------------------------------------------------------------
# 旧 contracts は EditMetadata を export していたため、外部呼び出し側を一気に
# 直さなくて済むよう alias を残す。新規コードは EngineMetadata を使うこと。
EditMetadata = EngineMetadata
