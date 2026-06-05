"""Bedrock GENERATE engine (Stability AI on Bedrock).

Stability text-to-image SKUs that are currently ACTIVE on us-west-2:
  - stability.stable-image-ultra-v1:1   (high quality, slower)
  - stability.stable-image-core-v1:1    (fast, cheaper)
  - stability.sd3-5-large-v1:0          (text-to-image / image-to-image)

All three return ``{seeds, finish_reasons, images: [<base64-png>]}``.

Prompt localisation is handled UPSTREAM by the VLM slot in mode="translate"
(see stream/app.py:_run_generate_pipeline). This engine intentionally does
NOT translate or rewrite prompts itself — that lets the operator pick which
VLM (Bedrock Claude / Trainium Qwen3-VL) does the rewrite.

Region / model id are overridable via env:
  - GENERATE_BEDROCK_REGION   (default us-west-2)
  - GENERATE_BEDROCK_MODEL_ID (default stability.stable-image-ultra-v1:1)
"""
from __future__ import annotations

import json
import os
import time
from typing import Any, Optional

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from contracts import EngineError, GenerateRequest, GenerateResponse
from engines._common import build_metadata
from engines.generate.base import ImageGenerateEngine


_DEFAULT_REGION = "us-west-2"
_DEFAULT_MODEL_ID = "stability.stable-image-ultra-v1:1"


class StabilityBedrockGenerateEngine(ImageGenerateEngine):
    """Stability AI text-to-image on Bedrock."""

    name = "bedrock_stability"

    def __init__(
        self,
        model_id: str | None = None,
        region: str | None = None,
        engine_name: str | None = None,
    ) -> None:
        # Stability text-to-image SKUs are only ACTIVE in us-west-2 today,
        # so we MUST NOT fall back to BEDROCK_REGION (which the rest of the
        # service points at us-east-1 for Nova / Claude). Honour an explicit
        # GENERATE_BEDROCK_REGION override; otherwise default to us-west-2.
        self.region = (
            region
            or os.environ.get("GENERATE_BEDROCK_REGION")
            or _DEFAULT_REGION
        )
        self.model_id = (
            model_id
            or os.environ.get("GENERATE_BEDROCK_MODEL_ID")
            or _DEFAULT_MODEL_ID
        )
        if engine_name:
            self.name = engine_name
        self._client = boto3.client("bedrock-runtime", region_name=self.region)

    def invoke(self, req: GenerateRequest) -> GenerateResponse:
        start = time.monotonic()
        body = self._build_body(req)
        try:
            resp = self._client.invoke_model(
                modelId=self.model_id,
                body=json.dumps(body),
                contentType="application/json",
                accept="application/json",
            )
        except (ClientError, BotoCoreError) as exc:
            raise EngineError(
                "provider_error",
                f"bedrock invoke_model failed: {exc}",
                retryable=True,
            ) from exc

        try:
            payload = json.loads(resp["body"].read())
        except (ValueError, json.JSONDecodeError) as exc:
            raise EngineError(
                "provider_invalid_response",
                f"unexpected Bedrock response shape: {exc}",
            ) from exc

        # Stability returns `finish_reasons: ["Filter reason: prompt"]` (or
        # similar) and OMITS the `images` key when its content filter
        # blocks the prompt. Surface that as a distinct error code so the
        # UI can tell the user the prompt was blocked vs the engine itself
        # failed.
        finish_reasons = payload.get("finish_reasons") or []
        block_reason = next(
            (r for r in finish_reasons if isinstance(r, str) and r), None
        )
        if block_reason:
            raise EngineError(
                "content_filtered",
                f"Stability blocked the prompt: {block_reason}. "
                "プロンプトを言い換えてもう一度試してください。",
                provider_detail={"finish_reasons": finish_reasons},
            )
        try:
            out_b64 = self._extract_image(payload)
        except KeyError as exc:
            raise EngineError(
                "provider_invalid_response",
                f"unexpected Bedrock response shape: {exc}",
            ) from exc

        return GenerateResponse(
            engine=self.name,
            image_b64=out_b64,
            metadata=build_metadata(
                model_id=self.model_id,
                start_monotonic=start,
                request_id=req.request_id,
                extra={
                    "bedrock_region": self.region,
                    "finish_reasons": payload.get("finish_reasons"),
                    "seeds": payload.get("seeds"),
                },
            ),
        )

    def _build_body(self, req: GenerateRequest) -> dict[str, Any]:
        """Build the Stability text-to-image request body.

        All three Stability SKUs accept the same minimum body
        ({prompt, mode}) and optional aspect_ratio / seed / output_format /
        negative_prompt.
        """
        body: dict[str, Any] = {
            "prompt": req.prompt,
            "mode": "text-to-image",
            "output_format": "png",
        }
        if req.options.aspect_ratio:
            body["aspect_ratio"] = req.options.aspect_ratio
        if req.options.seed is not None:
            body["seed"] = int(req.options.seed)
        if req.options.negative_prompt:
            body["negative_prompt"] = req.options.negative_prompt
        return body

    def _extract_image(self, payload: dict[str, Any]) -> str:
        images = payload.get("images") or []
        if not images:
            raise KeyError("images")
        # Stability returns one base64-encoded PNG per image. Pick the
        # first one — `numberOfImages` is implicitly 1 for these SKUs.
        return images[0]

