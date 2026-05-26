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
    """VLM スロットへの入力。

    mode は 2 種類:
      - "instruction": 音声指示 + before 画像 → EDIT スロット用編集プロンプト
      - "review"     : 編集指示 + after 画像 → 編集結果のレビューコメント
    """

    image_b64: str
    prompt: str
    mode: str = "instruction"
    engine: Optional[str] = None
    request_id: Optional[str] = None

    @classmethod
    def from_dict(cls, d: dict[str, Any]) -> "VlmRequest":
        if not isinstance(d, dict):
            raise EngineError("invalid_request", "request body must be JSON object")
        if not d.get("image_b64"):
            raise EngineError("invalid_request", "image_b64 is required")
        if not d.get("prompt"):
            raise EngineError("invalid_request", "prompt is required")
        mode = d.get("mode") or "instruction"
        if mode not in {"instruction", "review"}:
            raise EngineError("invalid_request", f"unknown mode: {mode}")
        return cls(
            image_b64=d["image_b64"],
            prompt=d["prompt"],
            mode=mode,
            engine=d.get("engine"),
            request_id=d.get("request_id"),
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
# 後方互換 alias
# ---------------------------------------------------------------------------
# 旧 contracts は EditMetadata を export していたため、外部呼び出し側を一気に
# 直さなくて済むよう alias を残す。新規コードは EngineMetadata を使うこと。
EditMetadata = EngineMetadata
