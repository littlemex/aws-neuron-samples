"""Trainium 系 EDIT エンジン: Qwen-Image-Edit serve.py への薄い HTTP プロキシ。

サーバ側 (samples/models/qwen-image-edit/serve.py) は multipart/form-data の
``POST /infer`` を晒し、PNG bytes を直接返すので、ここでは EditRequest の
base64 image を multipart に詰め替えて送り、PNG bytes を base64 にして
EditResponse に乗せる。contracts.py を変えずに新サーバに向け替えられる。

接続先は環境変数で受け取る。ハードコード禁止。
- TRAINIUM_EDIT_URL    (例: http://internal-...:8081/infer)
- TRAINIUM_EDIT_MODEL_ID (default: Qwen/Qwen-Image-Edit-2511)
- TRAINIUM_EDIT_TIMEOUT_SECONDS (default: 300)  Diffusion は重いので長め
- TRAINIUM_EDIT_NEGATIVE_PROMPT_DEFAULT (default: "blurry, low quality, deformed, distorted")
- TRAINIUM_EDIT_NUM_INFERENCE_STEPS (default: 50)
- TRAINIUM_EDIT_TRUE_CFG_SCALE (default: 3.0)
"""
from __future__ import annotations

import base64
import json as _json
import os
import time
from typing import Any

import urllib3

from contracts import EditRequest, EditResponse, EngineError
from engines.edit.base import ImageEditEngine
from engines._common import (
    build_metadata,
    decode_image_b64,
    env_float,
    env_int,
    env_required,
    guess_image_mime,
    raise_for_status,
)


_DEFAULT_NEGATIVE_PROMPT = "blurry, low quality, deformed, distorted"


class TrainiumEditEngine(ImageEditEngine):
    name = "trainium"

    def __init__(self) -> None:
        self.endpoint = env_required("TRAINIUM_EDIT_URL", "TRAINIUM_BACKEND_URL")
        self.model_id = os.environ.get(
            "TRAINIUM_EDIT_MODEL_ID",
            os.environ.get("TRAINIUM_MODEL_ID", "Qwen/Qwen-Image-Edit-2511"),
        )
        self.timeout = env_float(
            "TRAINIUM_EDIT_TIMEOUT_SECONDS",
            300.0,
            fallback=("TRAINIUM_TIMEOUT_SECONDS",),
        )
        self.default_negative_prompt = os.environ.get(
            "TRAINIUM_EDIT_NEGATIVE_PROMPT_DEFAULT", _DEFAULT_NEGATIVE_PROMPT
        )
        self.num_inference_steps = env_int("TRAINIUM_EDIT_NUM_INFERENCE_STEPS", 50)
        self.true_cfg_scale = env_float("TRAINIUM_EDIT_TRUE_CFG_SCALE", 3.0)
        self._http = urllib3.PoolManager(
            timeout=urllib3.Timeout(connect=10.0, read=self.timeout)
        )

    def invoke(self, req: EditRequest) -> EditResponse:
        start = time.monotonic()
        image_bytes = decode_image_b64(req.image_b64)

        seed = req.options.seed if req.options.seed is not None else 42
        negative_prompt = (
            req.options.negative_prompt
            if req.options.negative_prompt is not None
            else self.default_negative_prompt
        )

        fields = {
            "image1": (
                "input.png",
                image_bytes,
                guess_image_mime(image_bytes),
            ),
            "prompt": req.prompt,
            "negative_prompt": negative_prompt,
            "num_inference_steps": str(self.num_inference_steps),
            "true_cfg_scale": str(self.true_cfg_scale),
            "seed": str(seed),
        }

        try:
            resp = self._http.request(
                "POST",
                self.endpoint,
                fields=fields,
                retries=False,
            )
        except urllib3.exceptions.HTTPError as exc:
            raise EngineError(
                "provider_error",
                f"trainium edit backend unreachable: {exc}",
                retryable=True,
            ) from exc

        # EDIT は旧来 4xx を provider_error retryable=False で返していたので踏襲する。
        raise_for_status(resp, label="trainium edit", four_xx_code="provider_error")

        out_bytes = resp.data
        content_type = resp.headers.get("Content-Type", "")
        if content_type.startswith("application/json"):
            # 後方互換: 旧サーバが {image_b64: ...} JSON を返す場合
            try:
                body: dict[str, Any] = _json.loads(out_bytes.decode("utf-8"))
                out_b64 = body["image_b64"]
            except (KeyError, ValueError, UnicodeDecodeError) as exc:
                raise EngineError(
                    "provider_invalid_response",
                    f"trainium edit returned JSON without image_b64: {exc}",
                ) from exc
        elif content_type.startswith("image/"):
            out_b64 = base64.b64encode(out_bytes).decode("ascii")
        else:
            raise EngineError(
                "provider_invalid_response",
                f"trainium edit returned unexpected content-type: {content_type!r}",
                provider_detail={"content_type": content_type, "size": len(out_bytes)},
            )

        infer_time_header = resp.headers.get("X-Inference-Time")

        return EditResponse(
            engine=self.name,
            image_b64=out_b64,
            metadata=build_metadata(
                model_id=self.model_id,
                start_monotonic=start,
                request_id=req.request_id,
                extra={
                    "endpoint": self.endpoint,
                    "x_inference_time": infer_time_header,
                    "num_inference_steps": self.num_inference_steps,
                    "true_cfg_scale": self.true_cfg_scale,
                    "seed": seed,
                },
            ),
        )
