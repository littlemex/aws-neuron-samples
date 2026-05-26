"""Trainium 系 EDIT エンジン: Qwen-Image-Edit 等の自前サービングへの薄い HTTP プロキシ。

接続先は環境変数で受け取る。ハードコード禁止。
- TRAINIUM_EDIT_URL    (例: http://internal-...:8081/edit)
- TRAINIUM_EDIT_MODEL_ID (default: Qwen/Qwen-Image-Edit-2511)
- TRAINIUM_EDIT_TIMEOUT_SECONDS (default: 60)

サーバ側 (serve.py 等) の I/O はここでだけマッピングする。
contracts.py を変えずに新サーバに向け替えられる。
"""
from __future__ import annotations

import json as _json
import os
import time
import uuid
from typing import Any

import urllib3

from contracts import EditRequest, EditResponse, EngineError, EngineMetadata
from engines.edit.base import ImageEditEngine


class TrainiumEditEngine(ImageEditEngine):
    name = "trainium"

    def __init__(self) -> None:
        url = os.environ.get("TRAINIUM_EDIT_URL") or os.environ.get("TRAINIUM_BACKEND_URL")
        if not url:
            raise EngineError(
                "config_missing", "TRAINIUM_EDIT_URL env var is required"
            )
        # URL は完全な /edit endpoint を渡してもよいし、ベース URL を渡してもよい。
        self.endpoint = url
        self.model_id = os.environ.get(
            "TRAINIUM_EDIT_MODEL_ID",
            os.environ.get("TRAINIUM_MODEL_ID", "Qwen/Qwen-Image-Edit-2511"),
        )
        self.timeout = float(
            os.environ.get(
                "TRAINIUM_EDIT_TIMEOUT_SECONDS",
                os.environ.get("TRAINIUM_TIMEOUT_SECONDS", "60"),
            )
        )
        self._http = urllib3.PoolManager(
            timeout=urllib3.Timeout(connect=5.0, read=self.timeout)
        )

    def invoke(self, req: EditRequest) -> EditResponse:
        start = time.monotonic()
        payload = {
            "image_b64": req.image_b64,
            "prompt": req.prompt,
            "strength": req.options.strength,
            "seed": req.options.seed,
            "negative_prompt": req.options.negative_prompt,
        }
        try:
            resp = self._http.request(
                "POST",
                self.endpoint,
                body=_json.dumps(payload).encode("utf-8"),
                headers={"Content-Type": "application/json"},
            )
        except urllib3.exceptions.HTTPError as exc:
            raise EngineError(
                "provider_error",
                f"trainium edit backend unreachable: {exc}",
                retryable=True,
            ) from exc

        if resp.status >= 500:
            raise EngineError(
                "provider_error",
                f"trainium edit backend 5xx: status={resp.status}",
                retryable=True,
                provider_detail={"status": resp.status},
            )
        if resp.status >= 400:
            raise EngineError(
                "provider_error",
                f"trainium edit backend 4xx: status={resp.status}",
                retryable=False,
                provider_detail={"status": resp.status},
            )

        try:
            body: dict[str, Any] = _json.loads(resp.data.decode("utf-8"))
            out_b64 = body["image_b64"]
        except (KeyError, ValueError) as exc:
            raise EngineError(
                "provider_invalid_response",
                f"unexpected trainium edit response: {exc}",
            ) from exc

        return EditResponse(
            engine=self.name,
            image_b64=out_b64,
            metadata=EngineMetadata(
                model_id=self.model_id,
                latency_ms=int((time.monotonic() - start) * 1000),
                request_id=req.request_id or str(uuid.uuid4()),
                extra={"endpoint": self.endpoint},
            ),
        )
