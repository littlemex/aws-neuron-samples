"""Bedrock 系 VLM エンジン (Claude Sonnet / Nova Pro / Nova Lite)。

実装方針:
  - Bedrock Converse API (``bedrock-runtime.converse``) を使い、Claude / Nova 系の
    リクエスト形式差を吸収する。Converse API は ``messages[*].content[*]`` で
    image / text を混ぜて送る統一インタフェースを提供する。
  - mode は 2 種類:
      "instruction" : 音声指示 + before 画像 → EDIT 用編集プロンプトを 1 行で返す。
      "review"      : 編集指示 + after 画像 → 日本語の短いレビューコメントを返す。
    どちらも system prompt で出力フォーマットを縛る。

環境変数:
  - BEDROCK_REGION (必須)
  - BEDROCK_VLM_MODEL_ID  (registry 側でモデル ID を渡すケースが主、env は fallback)
  - VLM_INSTRUCTION_PROMPT_OVERRIDE / VLM_REVIEW_PROMPT_OVERRIDE (任意)
"""
from __future__ import annotations

import base64
import os
import time
import uuid
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from contracts import EngineError, EngineMetadata, VlmRequest, VlmResponse
from engines.vlm.base import VlmEngine


_DEFAULT_INSTRUCTION_PROMPT = (
    "You are an assistant that converts a user's voice instruction into an"
    " image-editing prompt for a downstream image editor."
    " Look at the BEFORE image and the user's instruction, then output ONE concise"
    " English sentence describing the edit (no preface, no quotes, no explanation)."
    " Keep nouns and modifiers explicit (color, material, position) so the editor"
    " can act without ambiguity. Do not invent edits the user did not request."
)

_DEFAULT_REVIEW_PROMPT = (
    "あなたは画像編集の品質をレビューするアシスタントです。"
    " ユーザーの編集指示と編集後画像 (AFTER) を見て、3 行以内の日本語で"
    " (1) 指示が反映されているか / (2) 違和感や破綻がないか / (3) 改善案"
    " を簡潔に述べてください。前置きや謝辞は不要です。"
)


class BedrockVlmEngine(VlmEngine):
    """Claude / Nova Pro / Nova Lite を 1 クラスでカバーする Bedrock VLM エンジン。"""

    name = "bedrock_vlm"

    def __init__(
        self,
        model_id: str | None = None,
        engine_name: str | None = None,
    ) -> None:
        region = os.environ.get("BEDROCK_REGION") or os.environ.get("AWS_REGION")
        if not region:
            raise EngineError(
                "config_missing", "BEDROCK_REGION env var is required"
            )
        resolved_model_id = model_id or os.environ.get("BEDROCK_VLM_MODEL_ID")
        if not resolved_model_id:
            raise EngineError(
                "config_missing",
                "BEDROCK_VLM_MODEL_ID env var is required",
            )
        self.region = region
        self.model_id = resolved_model_id
        if engine_name:
            self.name = engine_name
        self._client = boto3.client("bedrock-runtime", region_name=region)

    def invoke(self, req: VlmRequest) -> VlmResponse:
        start = time.monotonic()
        try:
            image_bytes = base64.b64decode(req.image_b64, validate=True)
        except (ValueError, TypeError) as exc:
            raise EngineError(
                "invalid_request", f"image_b64 is not valid base64: {exc}"
            ) from exc
        if not image_bytes:
            raise EngineError("invalid_request", "image_b64 decoded to empty bytes")

        system_prompt = _resolve_system_prompt(req.mode)
        image_format = _guess_image_format(image_bytes)

        try:
            resp = self._client.converse(
                modelId=self.model_id,
                system=[{"text": system_prompt}],
                messages=[
                    {
                        "role": "user",
                        "content": [
                            {
                                "image": {
                                    "format": image_format,
                                    "source": {"bytes": image_bytes},
                                }
                            },
                            {"text": req.prompt},
                        ],
                    }
                ],
                inferenceConfig={"maxTokens": 512, "temperature": 0.2},
            )
        except (ClientError, BotoCoreError) as exc:
            raise EngineError(
                "provider_error",
                f"bedrock converse failed: {exc}",
                retryable=True,
            ) from exc

        text = _extract_text(resp)
        if not text:
            raise EngineError(
                "provider_invalid_response",
                "bedrock converse returned empty text",
                provider_detail={"stopReason": resp.get("stopReason")},
            )

        usage = resp.get("usage") or {}
        return VlmResponse(
            engine=self.name,
            text=text,
            metadata=EngineMetadata(
                model_id=self.model_id,
                latency_ms=int((time.monotonic() - start) * 1000),
                request_id=req.request_id or str(uuid.uuid4()),
                extra={
                    "region": self.region,
                    "mode": req.mode,
                    "input_tokens": usage.get("inputTokens"),
                    "output_tokens": usage.get("outputTokens"),
                    "stop_reason": resp.get("stopReason"),
                },
            ),
        )


def _resolve_system_prompt(mode: str) -> str:
    if mode == "review":
        return os.environ.get("VLM_REVIEW_PROMPT_OVERRIDE") or _DEFAULT_REVIEW_PROMPT
    return (
        os.environ.get("VLM_INSTRUCTION_PROMPT_OVERRIDE")
        or _DEFAULT_INSTRUCTION_PROMPT
    )


def _guess_image_format(image_bytes: bytes) -> str:
    """Bedrock Converse API が受ける format string を magic byte から判定する。"""
    if image_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        return "png"
    if image_bytes.startswith(b"\xff\xd8\xff"):
        return "jpeg"
    if image_bytes.startswith(b"GIF87a") or image_bytes.startswith(b"GIF89a"):
        return "gif"
    if image_bytes[:4] == b"RIFF" and image_bytes[8:12] == b"WEBP":
        return "webp"
    # 不明な場合は png を仮定 (Bedrock 側で reject されたら provider_error で返る)
    return "png"


def _extract_text(resp: dict[str, Any]) -> str:
    output = resp.get("output") or {}
    message = output.get("message") or {}
    parts = message.get("content") or []
    chunks: list[str] = []
    for p in parts:
        if isinstance(p, dict) and isinstance(p.get("text"), str):
            chunks.append(p["text"])
    return "\n".join(c.strip() for c in chunks if c.strip()).strip()
