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
  - TRAINIUM_VLM_MODEL_ID (default: Qwen/Qwen3-VL-8B-Thinking)
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
    DEFAULT_TRANSLATE_PROMPT,
    build_review_prompt,
)
from engines._common import (
    build_metadata,
    decode_image_b64,
    env_float,
    env_int,
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
            "TRAINIUM_VLM_MODEL_ID", "Qwen/Qwen3-VL-8B-Thinking"
        )
        self.timeout = env_float("TRAINIUM_VLM_TIMEOUT_SECONDS", 300.0)
        self.api_key = os.environ.get("TRAINIUM_VLM_API_KEY")
        self.strip_thinking = os.environ.get(
            "TRAINIUM_VLM_STRIP_THINKING", "1"
        ).strip() not in {"0", "false", "False", ""}
        self._http = urllib3.PoolManager()

    def invoke(self, req: VlmRequest) -> VlmResponse:
        start = time.monotonic()
        system_prompt = _resolve_system_prompt(req.mode, req.language)

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

        # Qwen3-VL-Thinking emits long English reasoning inside
        # <think>...</think>. With the stock max_tokens=512 the closing tag
        # never landed before truncation, so strip_thinking returned the
        # raw English reasoning as the answer. We disable thinking via
        # vLLM's ``chat_template_kwargs.enable_thinking=False`` and keep a
        # generous output budget for review (still small for a sentence).
        # Other modes (instruction / translate) keep the legacy budget.
        is_review = req.mode == "review"
        max_tokens = env_int(
            "TRAINIUM_VLM_REVIEW_MAX_TOKENS" if is_review else "TRAINIUM_VLM_MAX_TOKENS",
            256 if is_review else 1024,
        )
        body: dict[str, Any] = {
            "model": self.model_id,
            "messages": [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": user_content},
            ],
            "temperature": 0.1 if is_review else 0.2,
            "top_p": 0.9,
            "max_tokens": max_tokens,
            # Disable Qwen3 thinking so the worker spends its budget on
            # the answer, not on English chain-of-thought. vLLM forwards
            # this to the chat template (Qwen3 official param).
            "chat_template_kwargs": {"enable_thinking": False},
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

        text, was_stripped = (
            strip_thinking(raw_text) if self.strip_thinking else (raw_text, False)
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


def _resolve_system_prompt(mode: str, language: str | None = None) -> str:
    if mode == "review":
        return (
            os.environ.get("VLM_REVIEW_PROMPT_OVERRIDE")
            or build_review_prompt(language)
        )
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
