"""Bedrock 系 EDIT エンジン (Nova Canvas など)。

Bedrock リージョンとモデル ID は環境変数で外から差し替える前提。ハードコード禁止。
- BEDROCK_REGION
- BEDROCK_EDIT_MODEL_ID  (例: amazon.nova-canvas-v1:0)

新しい Bedrock 系編集モデルが増えたら、本クラスを継承して _build_body / 応答 parser を
上書きするだけで済むように taskType / 応答 shape は private メソッドに切ってある。
"""
from __future__ import annotations

import json
import time
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError

from contracts import EditRequest, EditResponse, EngineError
from engines.edit.base import ImageEditEngine
from engines._common import build_metadata, env_required


class BedrockEditEngine(ImageEditEngine):
    """Nova Canvas IMAGE_VARIATION を既定実装として持つ Bedrock 編集エンジン。"""

    name = "bedrock_nova_canvas"

    def __init__(
        self,
        model_id: str | None = None,
        engine_name: str | None = None,
    ) -> None:
        self.region = env_required("BEDROCK_REGION")
        if model_id:
            self.model_id = model_id
        else:
            self.model_id = env_required(
                "BEDROCK_EDIT_MODEL_ID", "NOVA_CANVAS_MODEL_ID"
            )
        if engine_name:
            self.name = engine_name
        self._client = boto3.client("bedrock-runtime", region_name=self.region)

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
            out_b64 = self._extract_image(payload)
        except (KeyError, ValueError, json.JSONDecodeError) as exc:
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
                extra={"bedrock_region": self.region},
            ),
        )

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
