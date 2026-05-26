"""Trainium 系 VLM エンジン: Qwen3-VL 等の OpenAI 互換サーバへの薄い HTTP プロキシ。

設計:
  - OpenAI Chat Completions の形 (``messages[*].content[*]``) で送る。画像は
    ``image_url`` の data: URI で base64 inline。多くの OSS サーバ (vLLM,
    SGLang など) がこの形に準拠しているため、特定の Qwen 拡張に依存しない。
  - 応答は ``choices[0].message.content`` を取り出して text として返す。

環境変数 (ハードコード禁止):
  - TRAINIUM_VLM_URL  (例: http://internal-...:8090/v1/chat/completions)
  - TRAINIUM_VLM_MODEL_ID (default: Qwen/Qwen3-VL-8B-Thinking)
  - TRAINIUM_VLM_TIMEOUT_SECONDS (default: 60)
  - TRAINIUM_VLM_API_KEY (任意。Bearer ヘッダで送る)
"""
from __future__ import annotations

import base64
import json
import os
import time
import uuid

import urllib3

from contracts import EngineError, EngineMetadata, VlmRequest, VlmResponse
from engines.vlm.base import VlmEngine

_DEFAULT_INSTRUCTION_PROMPT = (
    "You are an assistant that converts a user's voice instruction into an"
    " image-editing prompt for a downstream image editor."
    " Look at the BEFORE image and the user's instruction, then output ONE concise"
    " English sentence describing the edit (no preface, no quotes, no explanation)."
)
_DEFAULT_REVIEW_PROMPT = (
    "あなたは画像編集の品質をレビューするアシスタントです。"
    " 編集指示と編集後画像 (AFTER) を見て、3 行以内の日本語で"
    " (1) 指示が反映されているか / (2) 違和感や破綻がないか / (3) 改善案 を簡潔に述べてください。"
)


class TrainiumVlmEngine(VlmEngine):
    name = "trainium"

    def __init__(self) -> None:
        url = os.environ.get("TRAINIUM_VLM_URL")
        if not url:
            raise EngineError(
                "config_missing", "TRAINIUM_VLM_URL env var is required"
            )
        self.endpoint = url
        self.model_id = os.environ.get(
            "TRAINIUM_VLM_MODEL_ID", "Qwen/Qwen3-VL-8B-Thinking"
        )
        self.timeout = float(
            os.environ.get("TRAINIUM_VLM_TIMEOUT_SECONDS", "60")
        )
        self.api_key = os.environ.get("TRAINIUM_VLM_API_KEY")
        self._http = urllib3.PoolManager()

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

        mime = _guess_image_mime(image_bytes)
        data_uri = f"data:{mime};base64,{req.image_b64}"
        system_prompt = (
            os.environ.get("VLM_REVIEW_PROMPT_OVERRIDE") or _DEFAULT_REVIEW_PROMPT
            if req.mode == "review"
            else os.environ.get("VLM_INSTRUCTION_PROMPT_OVERRIDE")
            or _DEFAULT_INSTRUCTION_PROMPT
        )

        body = {
            "model": self.model_id,
            "messages": [
                {"role": "system", "content": system_prompt},
                {
                    "role": "user",
                    "content": [
                        {"type": "image_url", "image_url": {"url": data_uri}},
                        {"type": "text", "text": req.prompt},
                    ],
                },
            ],
            "temperature": 0.2,
            "max_tokens": 512,
        }
        headers = {"Content-Type": "application/json"}
        if self.api_key:
            headers["Authorization"] = f"Bearer {self.api_key}"

        try:
            resp = self._http.request(
                "POST",
                self.endpoint,
                body=json.dumps(body).encode("utf-8"),
                headers=headers,
                timeout=urllib3.Timeout(connect=5.0, read=self.timeout),
                retries=False,
            )
        except urllib3.exceptions.HTTPError as exc:
            raise EngineError(
                "provider_error",
                f"trainium vlm request failed: {exc}",
                retryable=True,
            ) from exc

        if resp.status >= 500:
            raise EngineError(
                "provider_error",
                f"trainium vlm returned {resp.status}",
                retryable=True,
                provider_detail={"body": resp.data[:512].decode("utf-8", "replace")},
            )
        if resp.status >= 400:
            raise EngineError(
                "provider_invalid_response",
                f"trainium vlm returned {resp.status}",
                provider_detail={"body": resp.data[:512].decode("utf-8", "replace")},
            )

        try:
            payload = json.loads(resp.data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise EngineError(
                "provider_invalid_response",
                f"trainium vlm returned non-JSON: {exc}",
            ) from exc

        text = _extract_text(payload)
        if not text:
            raise EngineError(
                "provider_invalid_response",
                "trainium vlm response missing 'choices[0].message.content'",
                provider_detail={"keys": list(payload.keys())},
            )

        usage = payload.get("usage") or {}
        return VlmResponse(
            engine=self.name,
            text=text,
            metadata=EngineMetadata(
                model_id=self.model_id,
                latency_ms=int((time.monotonic() - start) * 1000),
                request_id=req.request_id or str(uuid.uuid4()),
                extra={
                    "endpoint": self.endpoint,
                    "mode": req.mode,
                    "prompt_tokens": usage.get("prompt_tokens"),
                    "completion_tokens": usage.get("completion_tokens"),
                },
            ),
        )


def _guess_image_mime(image_bytes: bytes) -> str:
    if image_bytes.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if image_bytes.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if image_bytes.startswith(b"GIF87a") or image_bytes.startswith(b"GIF89a"):
        return "image/gif"
    if image_bytes[:4] == b"RIFF" and image_bytes[8:12] == b"WEBP":
        return "image/webp"
    return "image/png"


def _extract_text(payload: dict) -> str:
    choices = payload.get("choices") or []
    if not choices:
        return ""
    msg = choices[0].get("message") or {}
    content = msg.get("content")
    if isinstance(content, str):
        return content.strip()
    if isinstance(content, list):
        chunks: list[str] = []
        for part in content:
            if isinstance(part, dict) and isinstance(part.get("text"), str):
                chunks.append(part["text"])
        return "\n".join(c.strip() for c in chunks if c.strip()).strip()
    return ""
