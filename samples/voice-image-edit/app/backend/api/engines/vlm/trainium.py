"""Trainium 系 VLM エンジン: Qwen3-VL 等の OpenAI 互換サーバへの薄い HTTP プロキシ。

設計:
  - OpenAI Chat Completions の形 (``messages[*].content[*]``) で送る。画像は
    ``image_url`` の data: URI で base64 inline。多くの OSS サーバ (vLLM,
    SGLang など) がこの形に準拠しているため、特定の Qwen 拡張に依存しない。
  - 応答は ``choices[0].message.content`` を取り出して text として返す。
  - Qwen3-VL-Thinking など <think>...</think> CoT を含むモデルでは、
    上位層 (Bedrock 系と同等の出力契約) のために thinking ブロックを除去し、
    raw を ``metadata.extra["raw_text"]`` に退避する。

環境変数 (ハードコード禁止):
  - TRAINIUM_VLM_URL  (例: http://internal-...:8090/v1/chat/completions)
  - TRAINIUM_VLM_MODEL_ID (default: Qwen/Qwen3-VL-8B-Instruct)
  - TRAINIUM_VLM_TIMEOUT_SECONDS (default: 300)
  - TRAINIUM_VLM_API_KEY (任意。Bearer ヘッダで送る)
  - TRAINIUM_VLM_STRIP_THINKING (default: "1"。"0" で無効化)
"""
from __future__ import annotations

import json
import os
import time
from typing import Any

import urllib3

from contracts import EngineError, VlmRequest, VlmResponse
from engines.vlm.base import VlmEngine
from engines.vlm._prompts import (
    DEFAULT_INSTRUCTION_PROMPT,
    DEFAULT_REVIEW_PROMPT,
    DEFAULT_TRANSLATE_PROMPT,
)
from engines._common import (
    build_metadata,
    decode_image_b64,
    env_float,
    env_required,
    guess_image_mime,
    raise_for_status,
    strip_thinking,
)
# All prompt strings live in engines/vlm/_prompts.py so Bedrock and Trainium
# share the exact same instruction / review / translate text. Engine-specific
# wording shifts here would silently diverge the two providers.


class TrainiumVlmEngine(VlmEngine):
    name = "trainium"

    def __init__(self) -> None:
        self.endpoint = env_required("TRAINIUM_VLM_URL")
        self.model_id = os.environ.get(
            "TRAINIUM_VLM_MODEL_ID", "Qwen/Qwen3-VL-8B-Instruct"
        )
        self.timeout = env_float("TRAINIUM_VLM_TIMEOUT_SECONDS", 300.0)
        self.api_key = os.environ.get("TRAINIUM_VLM_API_KEY")
        self.strip_thinking = os.environ.get(
            "TRAINIUM_VLM_STRIP_THINKING", "1"
        ).strip() not in {"0", "false", "False", ""}
        self._http = urllib3.PoolManager()

    def invoke(self, req: VlmRequest) -> VlmResponse:
        start = time.monotonic()
        system_prompt = _resolve_system_prompt(req.mode)

        # Build user content: image+text for instruction/review, text-only
        # for translate. The OpenAI Chat schema accepts either a string or
        # a list of content parts; we always send the list form for image
        # modes and a plain string for translate so models that reject
        # vision-style content for text-only prompts still work.
        if req.mode == "translate":
            user_content: Any = req.prompt
        else:
            image_bytes = decode_image_b64(req.image_b64)
            mime = guess_image_mime(image_bytes)
            data_uri = f"data:{mime};base64,{req.image_b64}"
            user_content = [
                {"type": "image_url", "image_url": {"url": data_uri}},
                {"type": "text", "text": req.prompt},
            ]

        body = {
            "model": self.model_id,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
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

        raise_for_status(resp, label="trainium vlm")

        try:
            payload = json.loads(resp.data.decode("utf-8"))
        except (ValueError, UnicodeDecodeError) as exc:
            raise EngineError(
                "provider_invalid_response",
                f"trainium vlm returned non-JSON: {exc}",
            ) from exc

        raw_text = _extract_text(payload)
        if not raw_text:
            raise EngineError(
                "provider_invalid_response",
                "trainium vlm response missing 'choices[0].message.content'",
                provider_detail={"keys": list(payload.keys())},
            )

        # ``language`` flows through into the language-aware filter inside
        # strip_thinking. For review mode this strips out Qwen3 thinking
        # written in English or Chinese without relying on <think> tags
        # (the Neuron build of vLLM does not split reasoning_content even
        # when --reasoning-parser qwen3 is set). Other modes pass language=None
        # so the filter is a no-op and instruction / translate keep all text.
        # If the caller (frontend) did not send a language we default to the
        # product spec language (Japanese) for review so the filter still
        # runs and reasoning never reaches the UI.
        filter_lang = (req.language or "ja") if req.mode == "review" else None
        text, was_stripped = (
            strip_thinking(raw_text, language=filter_lang)
            if self.strip_thinking
            else (raw_text, False)
        )
        if not text and self.strip_thinking:
            # The thinking filter consumed everything, which means the
            # model never produced an answer in the requested language
            # (typical when the budget was eaten by reasoning). Surface
            # a retryable error rather than returning the reasoning blob.
            raise EngineError(
                "provider_invalid_response",
                "trainium vlm returned only reasoning content; no answer in requested language",
                retryable=True,
                provider_detail={"raw_excerpt": raw_text[:300], "language": filter_lang},
            )

        usage = payload.get("usage") or {}
        extra = {
            "endpoint": self.endpoint,
            "mode": req.mode,
            "prompt_tokens": usage.get("prompt_tokens"),
            "completion_tokens": usage.get("completion_tokens"),
        }
        if was_stripped:
            extra["raw_text"] = raw_text
            extra["thinking_stripped"] = True

        return VlmResponse(
            engine=self.name,
            text=text,
            metadata=build_metadata(
                model_id=self.model_id,
                start_monotonic=start,
                request_id=req.request_id,
                extra=extra,
            ),
        )


def _resolve_system_prompt(mode: str) -> str:
    if mode == "review":
        return os.environ.get("VLM_REVIEW_PROMPT_OVERRIDE") or DEFAULT_REVIEW_PROMPT
    if mode == "translate":
        return os.environ.get("VLM_TRANSLATE_PROMPT_OVERRIDE") or DEFAULT_TRANSLATE_PROMPT
    return os.environ.get("VLM_INSTRUCTION_PROMPT_OVERRIDE") or DEFAULT_INSTRUCTION_PROMPT


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
