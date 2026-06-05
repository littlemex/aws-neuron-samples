"""Bedrock EDIT engines (image-to-image).

Two concrete engines coexist in this module so the operator can switch via
the GENERATE/EDIT registry without code changes:

  - NovaCanvasEditEngine
      Region : env BEDROCK_REGION (typically us-east-1).
      Model  : amazon.nova-canvas-v1:0 (LEGACY but still callable).
      Body   : IMAGE_VARIATION task with similarityStrength.

  - StabilitySd35EditEngine
      Region : us-west-2 by default (the only ACTIVE Stability region).
      Model  : stability.sd3-5-large-v1:0 (text-to-image / image-to-image).
      Body   : flat ``{prompt, mode: image-to-image, image, strength}``.

Shared scaffolding lives in ``BedrockEditEngineBase``:
    invoke()              - one boto3 client per engine, latency timing,
                            error wrapping.
    _build_body()         - subclass-specific request body.
    _extract_image()      - subclass-specific response parser.

Adding a new Bedrock image editor is a "subclass + 2 short methods" change.
"""
from __future__ import annotations

import json
import os
import time
from abc import abstractmethod
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from contracts import EditRequest, EditResponse, EngineError
from engines.edit.base import ImageEditEngine
from engines._common import build_metadata, env_required


class BedrockEditEngineBase(ImageEditEngine):
    """Shared boto3 / latency / error scaffolding for Bedrock image editors.

    Concrete subclasses provide a region resolver, a default model id, and
    request/response shape adapters.
    """

    name: str = "bedrock_edit_base"

    def __init__(
        self,
        model_id: str | None = None,
        region: str | None = None,
        engine_name: str | None = None,
    ) -> None:
        self.region = region or self._resolve_region()
        self.model_id = model_id or self._resolve_model_id()
        if engine_name:
            self.name = engine_name
        self._client = boto3.client("bedrock-runtime", region_name=self.region)

    # -- subclass hooks ----------------------------------------------------

    @abstractmethod
    def _resolve_region(self) -> str:
        """Return the AWS region for this engine's Bedrock client."""

    @abstractmethod
    def _resolve_model_id(self) -> str:
        """Return the Bedrock model id when no override is supplied."""

    @abstractmethod
    def _build_body(self, req: EditRequest) -> dict[str, Any]:
        """Build the InvokeModel body for this engine's request shape."""

    @abstractmethod
    def _extract_image(self, payload: dict[str, Any]) -> str:
        """Extract one base64 PNG out of the InvokeModel response."""

    # -- shared invoke -----------------------------------------------------

    def invoke(self, req: EditRequest) -> EditResponse:
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

        # Stability returns finish_reasons=["Filter reason: prompt"] and
        # omits the images key when the content filter blocks the prompt.
        # Surface that distinct error code for the UI.
        finish_reasons = payload.get("finish_reasons") or []
        block_reason = next(
            (r for r in finish_reasons if isinstance(r, str) and r), None
        )
        if block_reason:
            raise EngineError(
                "content_filtered",
                f"image editor blocked the prompt: {block_reason}. "
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

        return EditResponse(
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


# ---------------------------------------------------------------------------
# Nova Canvas (LEGACY but callable). Kept for environments where Stability is
# not yet enabled or for parity comparisons.
# ---------------------------------------------------------------------------


class NovaCanvasEditEngine(BedrockEditEngineBase):
    """Amazon Nova Canvas IMAGE_VARIATION."""

    name = "bedrock_nova_canvas"

    def _resolve_region(self) -> str:
        return env_required("BEDROCK_REGION")

    def _resolve_model_id(self) -> str:
        return env_required("BEDROCK_EDIT_MODEL_ID", "NOVA_CANVAS_MODEL_ID")

    def _build_body(self, req: EditRequest) -> dict[str, Any]:
        body: dict[str, Any] = {
            "taskType": "IMAGE_VARIATION",
            "imageVariationParams": {
                "text": req.prompt,
                "images": [req.image_b64],
                "similarityStrength": float(req.options.strength),
            },
            "imageGenerationConfig": {
                "numberOfImages": 1,
                "cfgScale": 7.0,
            },
        }
        if req.options.negative_prompt:
            body["imageVariationParams"]["negativeText"] = req.options.negative_prompt
        if req.options.seed is not None:
            body["imageGenerationConfig"]["seed"] = int(req.options.seed)
        return body

    def _extract_image(self, payload: dict[str, Any]) -> str:
        images = payload.get("images") or []
        if not images:
            raise KeyError("images")
        return images[0]


# ---------------------------------------------------------------------------
# Stability SD 3.5 Large image-to-image. ACTIVE on us-west-2.
# ---------------------------------------------------------------------------

_DEFAULT_SD35_REGION = "us-west-2"
_DEFAULT_SD35_MODEL_ID = "stability.sd3-5-large-v1:0"


class StabilitySd35EditEngine(BedrockEditEngineBase):
    """Stability SD 3.5 Large in image-to-image mode.

    Stability rejects non-English prompts via its content filter, so the
    upstream pipeline (stream/app.py:_run_pipeline) is expected to route
    instruction prompts through the VLM slot first; that step already
    yields English. The ``EditRequest.prompt`` we receive here is treated
    as English. ``options.strength`` is forwarded as Stability's
    ``strength`` (0.0–1.0; higher = follow prompt more, change image more).
    """

    name = "bedrock_stability_sd35"

    def _resolve_region(self) -> str:
        # Stability lives in us-west-2; do NOT inherit BEDROCK_REGION
        # (which the Nova/Claude path points at us-east-1).
        return os.environ.get("EDIT_BEDROCK_REGION") or _DEFAULT_SD35_REGION

    def _resolve_model_id(self) -> str:
        return (
            os.environ.get("EDIT_BEDROCK_MODEL_ID")
            or os.environ.get("BEDROCK_STABILITY_SD35_MODEL_ID")
            or _DEFAULT_SD35_MODEL_ID
        )

    def _build_body(self, req: EditRequest) -> dict[str, Any]:
        body: dict[str, Any] = {
            "prompt": req.prompt,
            "mode": "image-to-image",
            "image": req.image_b64,
            "output_format": "png",
            "strength": float(req.options.strength),
        }
        if req.options.negative_prompt:
            body["negative_prompt"] = req.options.negative_prompt
        if req.options.seed is not None:
            body["seed"] = int(req.options.seed)
        return body

    def _extract_image(self, payload: dict[str, Any]) -> str:
        images = payload.get("images") or []
        if not images:
            raise KeyError("images")
        return images[0]


# ---------------------------------------------------------------------------
# Backwards-compatible alias.
# ---------------------------------------------------------------------------
# Older imports (`from engines.edit.bedrock import BedrockEditEngine`) still
# work and resolve to Nova Canvas, since that was the engine type before
# this module was split.
BedrockEditEngine = NovaCanvasEditEngine
