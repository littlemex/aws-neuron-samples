"""Bedrock VLM engine (Claude Sonnet / Nova Pro / Nova Lite).

Design:
  - Use the Bedrock Converse API so the request shape stays uniform across
    Claude and Nova families. Converse takes mixed image/text content via
    ``messages[*].content[*]``.
  - Three modes are honoured via system prompt selection:
      "instruction" : voice instruction + BEFORE image -> 1-line edit prompt
      "review"      : edit instruction + AFTER image  -> short review comment
      "translate"   : text only (no image)            -> English image prompt
                      used by the GENERATE slot to localise non-English voice.

Environment:
  - BEDROCK_REGION (required)
  - BEDROCK_VLM_MODEL_ID  (the registry passes a model id; env is a fallback)
  - VLM_INSTRUCTION_PROMPT_OVERRIDE / VLM_REVIEW_PROMPT_OVERRIDE
  - VLM_TRANSLATE_PROMPT_OVERRIDE  (optional; default is the canonical
    "rewrite as concise English image-gen prompt" template)
"""
from __future__ import annotations

import os
import time
from typing import Any, Optional

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from contracts import EngineError, VlmRequest, VlmResponse
from engines.vlm.base import VlmEngine
from engines.vlm._prompts import (
    DEFAULT_INSTRUCTION_PROMPT,
    DEFAULT_TRANSLATE_PROMPT,
    build_review_prompt,
)
from engines._common import (
    build_metadata,
    decode_image_b64,
    env_int,
    env_required,
    guess_image_format,
)


# All prompt strings live in engines/vlm/_prompts.py so Bedrock and Trainium
# share the exact same instruction / review / translate text. Engine-specific
# wording shifts here would silently diverge the two providers, which is the
# bug we just fixed.


class BedrockVlmEngine(VlmEngine):
    """Claude / Nova Pro / Nova Lite を 1 クラスでカバーする Bedrock VLM エンジン。"""

    name = "bedrock_vlm"

    def __init__(
        self,
        model_id: str | None = None,
        engine_name: str | None = None,
    ) -> None:
        self.region = env_required("BEDROCK_REGION", "AWS_REGION")
        if model_id:
            self.model_id = model_id
        else:
            self.model_id = env_required("BEDROCK_VLM_MODEL_ID")
        if engine_name:
            self.name = engine_name
        self._client = boto3.client("bedrock-runtime", region_name=self.region)

    def invoke(self, req: VlmRequest) -> VlmResponse:
        start = time.monotonic()
        system_prompt = _resolve_system_prompt(req.mode, req.language)
        # mode="translate" is text-only and intentionally skips the image
        # input. Other modes (instruction / review) require the BEFORE/AFTER
        # image like before.
        if req.mode == "translate":
            user_content: list[dict[str, Any]] = [{"text": req.prompt}]
            image_format: Optional[str] = None
        else:
            image_bytes = decode_image_b64(req.image_b64)
            image_format = guess_image_format(image_bytes)
            user_content = [
                {
                    "image": {
                        "format": image_format,
                        "source": {"bytes": image_bytes},
                    }
                },
                {"text": req.prompt},
            ]

        # review mode wants a single short sentence in the requested language.
        # other modes keep the legacy budget so existing edit / translate
        # quality is unchanged. Both are env-overridable for ad-hoc tuning.
        is_review = req.mode == "review"
        max_tokens = env_int(
            "BEDROCK_VLM_REVIEW_MAX_TOKENS" if is_review else "BEDROCK_VLM_MAX_TOKENS",
            120 if is_review else 512,
        )
        inference_config: dict[str, Any] = {
            "maxTokens": max_tokens,
            "temperature": 0.1 if is_review else 0.2,
            "topP": 0.9,
        }

        try:
            resp = self._client.converse(
                modelId=self.model_id,
                system=[{"text": system_prompt}],
                messages=[{"role": "user", "content": user_content}],
                inferenceConfig=inference_config,
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
            metadata=build_metadata(
                model_id=self.model_id,
                start_monotonic=start,
                request_id=req.request_id,
                extra={
                    "region": self.region,
                    "mode": req.mode,
                    "input_tokens": usage.get("inputTokens"),
                    "output_tokens": usage.get("outputTokens"),
                    "stop_reason": resp.get("stopReason"),
                },
            ),
        )


def _resolve_system_prompt(mode: str, language: str | None = None) -> str:
    if mode == "review":
        # Override (set per-deploy) wins; otherwise pick the language-specific
        # prompt. Other modes (instruction / translate) are language-fixed by
        # contract so no per-call language switch is needed.
        return (
            os.environ.get("VLM_REVIEW_PROMPT_OVERRIDE")
            or build_review_prompt(language)
        )
    if mode == "translate":
        return os.environ.get("VLM_TRANSLATE_PROMPT_OVERRIDE") or DEFAULT_TRANSLATE_PROMPT
    return (
        os.environ.get("VLM_INSTRUCTION_PROMPT_OVERRIDE")
        or DEFAULT_INSTRUCTION_PROMPT
    )


def _extract_text(resp: dict[str, Any]) -> str:
    output = resp.get("output") or {}
    message = output.get("message") or {}
    parts = message.get("content") or []
    chunks: list[str] = []
    for p in parts:
        if isinstance(p, dict) and isinstance(p.get("text"), str):
            chunks.append(p["text"])
    return "\n".join(c.strip() for c in chunks if c.strip()).strip()
