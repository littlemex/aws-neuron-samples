"""
voice-image-edit Stage 3 streaming backend (P8 skeleton + P9 pipeline)。

ALB の /stream/* ルールから IP target で受ける FastAPI app。SSE/WS の取り回しが
ALB 経由で問題なく動くかを最小コストで確認するためのスケルトンに、P9 で
4 段パイプラインの progress 配信エンドポイントを追加した。

エンドポイント:
  GET /stream/health
    プレーンな JSON 200。ALB の health check と Playwright の sanity 用。

  GET /stream/echo?message=...&count=N&interval_ms=M
    text/event-stream で N 件 (default 5) ぶんイベントを送る。
    各イベントは
        event: tick
        data: {"i":0, "message":"...", "ts": <epoch_ms>}
    の形。最後に
        event: done
        data: {"sent": N}
    を送ってクローズ。SSE プロキシ (CloudFront/ALB) のチャンク転送と
    keep-alive を踏み抜くのが目的なので副作用は持たない。

  POST /stream/pipeline (P9)
    body: {"image_b64": str, "user_instruction": str,
            "vlm_engine"?: str, "edit_engine"?: str,
            "request_id"?: str}
    挙動:
      1. VLM(instruction) を /api/edit/vlm に投げる (X-Origin-Verify を付ける)
      2. EDIT を /api/edit/edit に投げる (返値は presigned image_url)
      3. presigned URL から PNG を取って base64 化
      4. VLM(review) を /api/edit/vlm に投げる
    各段ごとに以下の SSE event を順序付きで吐く:
      event: pipeline_start    {request_id}
      event: stage_start       {stage}
      event: stage_complete    {stage, payload...}    # stage 固有の最小情報
      event: stage_error       {stage, code, message}
      event: pipeline_complete {request_id}
    review 段のエラーは pipeline 全体の致命とは扱わず、stage_error を出した上で
    pipeline_complete までは送る。これは UI 側の挙動 (review が落ちても
    edit 結果は維持) と揃えるため。

セキュリティ前提:
  - ALB listener rule が X-Origin-Verify header を完全一致でフィルタするので、
    本 app は自身の origin verify 検証は二重にやらない。
  - Cognito は CloudFront Function (cf_session HMAC) で弾かれる前提なので
    本 app は認証ロジックを持たない。
  - /stream/pipeline が /api/edit/* (EC2 systemd FastAPI, port 8801) を呼ぶときの
    X-Origin-Verify は systemd Environment 経由で env var として渡される
    (ORIGIN_VERIFY_HEADER_NAME / ORIGIN_VERIFY_HEADER_VALUE)。値はログ出力しない。
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
import uuid
from typing import Any, AsyncIterator, Optional

import httpx
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field


LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("voice-image-edit-stream")


# /stream/pipeline 用の /api/edit/* (EC2 FastAPI:8801) 接続設定。
# - EDIT_API_BASE_URL は ALB internal DNS で /api/edit を指す。
# - ORIGIN_VERIFY_HEADER_NAME / _VALUE は ALB rule と完全一致する必要あり。
# 値が無いと /stream/pipeline は 503 を返す (skeleton の echo / health は影響なし)。
_EDIT_API_BASE_URL = os.environ.get("EDIT_API_BASE_URL", "").rstrip("/")
_ORIGIN_VERIFY_HEADER_NAME = os.environ.get("ORIGIN_VERIFY_HEADER_NAME", "X-Origin-Verify")
_ORIGIN_VERIFY_HEADER_VALUE = os.environ.get("ORIGIN_VERIFY_HEADER_VALUE", "")
# 各段の network 上限。EDIT は Nova Canvas で数 10 秒かかるので長め、
# VLM / 画像 fetch は短めにして詰まりを早く落とす。
_HTTP_TIMEOUT_VLM_S = float(os.environ.get("STREAM_HTTP_TIMEOUT_VLM_S", "60"))
_HTTP_TIMEOUT_EDIT_S = float(os.environ.get("STREAM_HTTP_TIMEOUT_EDIT_S", "180"))
_HTTP_TIMEOUT_FETCH_S = float(os.environ.get("STREAM_HTTP_TIMEOUT_FETCH_S", "30"))


app = FastAPI(
    title="voice-image-edit-stream",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


def _sse_event(event: str, payload: dict[str, Any]) -> bytes:
    # SSE は CRLF/LF いずれでも良いが、ALB は LF を尊重する。空行 \n\n でフラッシュ。
    body = json.dumps(payload, ensure_ascii=False, separators=(",", ":"))
    return f"event: {event}\ndata: {body}\n\n".encode("utf-8")


@app.get("/stream/health")
async def health() -> JSONResponse:
    return JSONResponse(
        {
            "status": "ok",
            "service": "voice-image-edit-stream",
            "pipeline_configured": bool(_EDIT_API_BASE_URL and _ORIGIN_VERIFY_HEADER_VALUE),
        }
    )


@app.get("/stream/echo")
async def echo(
    message: str = Query("hello", max_length=200),
    count: int = Query(5, ge=1, le=50),
    interval_ms: int = Query(200, ge=0, le=5000),
) -> StreamingResponse:
    async def gen() -> AsyncIterator[bytes]:
        # ALB は最初の byte が来るまで idle timeout (default 60s) で切る可能性があるので、
        # 最初の event は遅延させずに送る。
        for i in range(count):
            payload = {"i": i, "message": message, "ts_ms": int(time.time() * 1000)}
            yield _sse_event("tick", payload)
            if interval_ms > 0 and i < count - 1:
                await asyncio.sleep(interval_ms / 1000)
        yield _sse_event("done", {"sent": count})

    headers = {
        # ALB / CloudFront / Browser それぞれ buffering を切るためのヒント。
        # CACHING_DISABLED な default behavior でも明示しておく。
        "Cache-Control": "no-cache, no-transform",
        "X-Accel-Buffering": "no",
        "Content-Type": "text/event-stream; charset=utf-8",
    }
    return StreamingResponse(gen(), media_type="text/event-stream", headers=headers)


# ---------------------------------------------------------------------------
# /stream/pipeline (P9): 4 段パイプラインの progress を SSE で押し出す
# ---------------------------------------------------------------------------


class PipelineRequest(BaseModel):
    """Edit pipeline input.

    Fields:
      - image_b64: BEFORE image (base64; no data: prefix)
      - user_instruction: voice-derived (or directly typed) instruction
      - vlm_engine / edit_engine / tts_engine: optional overrides
      - enable_tts: when true, append a tts stage that reads the review aloud
      - request_id: stream backend allocates one when missing
    """

    image_b64: str = Field(..., min_length=1)
    user_instruction: str = Field(..., min_length=1)
    vlm_engine: Optional[str] = None
    edit_engine: Optional[str] = None
    tts_engine: Optional[str] = None
    enable_tts: bool = False
    request_id: Optional[str] = None


def _pipeline_headers() -> dict[str, str]:
    return {
        "Cache-Control": "no-cache, no-transform",
        "X-Accel-Buffering": "no",
        "Content-Type": "text/event-stream; charset=utf-8",
    }


def _origin_verify_headers() -> dict[str, str]:
    # X-Origin-Verify を Lambda に通すための共通ヘッダ。値はログに出さない。
    return {_ORIGIN_VERIFY_HEADER_NAME: _ORIGIN_VERIFY_HEADER_VALUE}


def _stage_error_payload(stage: str, exc: Exception) -> dict[str, Any]:
    """例外を SSE stage_error で吐ける形に整形する。secret は含めない。"""
    code = "internal"
    message = str(exc)
    if isinstance(exc, httpx.HTTPStatusError):
        code = f"http_{exc.response.status_code}"
        try:
            body = exc.response.json()
            err = body.get("error") or {}
            code = err.get("code") or code
            message = err.get("message") or message
        except Exception:  # noqa: BLE001
            pass
    elif isinstance(exc, httpx.TimeoutException):
        code = "timeout"
    elif isinstance(exc, httpx.HTTPError):
        code = "network"
    return {"stage": stage, "code": code, "message": message}


async def _post_edit_api(
    client: httpx.AsyncClient, path: str, body: dict[str, Any], timeout_s: float
) -> dict[str, Any]:
    url = f"{_EDIT_API_BASE_URL}{path}"
    res = await client.post(url, json=body, headers=_origin_verify_headers(), timeout=timeout_s)
    res.raise_for_status()
    return res.json()


# CloudFront / ALB の idle timeout は 60s 程度。Trainium EDIT/VLM の long await 中に
# 接続が idle になって切られないよう、long await を heartbeat 付きで包む。
_HEARTBEAT_INTERVAL_S = float(os.environ.get("STREAM_HEARTBEAT_INTERVAL_S", "10"))


async def _stage_with_heartbeat(coro, stage: str) -> AsyncIterator[Any]:
    """coro を await しつつ、_HEARTBEAT_INTERVAL_S 間隔で stage_progress heartbeat を yield する。

    最終的に coro の戻り値は ("result", value) として yield。例外時は ("error", exc)。
    呼び元は (kind, payload) を受け取り、"heartbeat" は SSE bytes をそのまま yield、
    "result"/"error" は処理を分岐する。
    """
    task = asyncio.create_task(coro)
    try:
        while True:
            try:
                result = await asyncio.wait_for(asyncio.shield(task), timeout=_HEARTBEAT_INTERVAL_S)
                yield ("result", result)
                return
            except asyncio.TimeoutError:
                yield (
                    "heartbeat",
                    _sse_event(
                        "stage_progress",
                        {"stage": stage, "ts_ms": int(time.time() * 1000)},
                    ),
                )
            except Exception as exc:  # noqa: BLE001
                yield ("error", exc)
                return
    finally:
        if not task.done():
            task.cancel()
            try:
                await task
            except (asyncio.CancelledError, Exception):  # noqa: BLE001
                pass


async def _fetch_image_b64(client: httpx.AsyncClient, url: str) -> str:
    """presigned S3 GET を取得し base64 文字列として返す。"""
    import base64

    res = await client.get(url, timeout=_HTTP_TIMEOUT_FETCH_S)
    res.raise_for_status()
    return base64.b64encode(res.content).decode("ascii")


async def _run_pipeline(req: PipelineRequest) -> AsyncIterator[bytes]:
    request_id = req.request_id or str(uuid.uuid4())
    yield _sse_event("pipeline_start", {"request_id": request_id})

    if not _EDIT_API_BASE_URL or not _ORIGIN_VERIFY_HEADER_VALUE:
        yield _sse_event(
            "stage_error",
            {
                "stage": "config",
                "code": "config_missing",
                "message": "EDIT_API_BASE_URL / ORIGIN_VERIFY_HEADER_VALUE is not set",
            },
        )
        yield _sse_event("pipeline_complete", {"request_id": request_id})
        return

    # 1 つの AsyncClient を全段で使い回す (keep-alive)。
    async with httpx.AsyncClient(http2=False) as client:
        # ---- Stage 2: VLM (instruction) ---------------------------------
        # instruction is a text-only language transform (JA voice -> EN edit
        # prompt); it does not use the BEFORE image. We therefore do NOT send
        # image_b64 here — sending it was wasteful (a full base64 image copied
        # to the API for nothing) and, on the Neuron VLM, a large image would
        # overrun the vision bucket and crash the engine. review (Stage 4)
        # remains the only image-grounded VLM call.
        yield _sse_event("stage_start", {"stage": "vlm_instruction"})
        vlm_body: dict[str, Any] = {
            "prompt": req.user_instruction,
            "mode": "instruction",
            "request_id": request_id,
        }
        if req.vlm_engine:
            vlm_body["engine"] = req.vlm_engine
        vlm_res = None
        async for kind, payload in _stage_with_heartbeat(
            _post_edit_api(client, "/vlm", vlm_body, _HTTP_TIMEOUT_VLM_S),
            "vlm_instruction",
        ):
            if kind == "heartbeat":
                yield payload
            elif kind == "error":
                log.warning("pipeline vlm_instruction failed: %s", payload)
                yield _sse_event("stage_error", _stage_error_payload("vlm_instruction", payload))
                yield _sse_event("pipeline_complete", {"request_id": request_id})
                return
            else:
                vlm_res = payload

        edit_prompt = (vlm_res or {}).get("text") or ""
        yield _sse_event(
            "stage_complete",
            {
                "stage": "vlm_instruction",
                "engine": (vlm_res or {}).get("engine"),
                "text": edit_prompt,
                "metadata": (vlm_res or {}).get("metadata", {}),
            },
        )

        # ---- Stage 3: EDIT ----------------------------------------------
        yield _sse_event("stage_start", {"stage": "edit"})
        edit_body: dict[str, Any] = {
            "image_b64": req.image_b64,
            "prompt": edit_prompt,
            "request_id": request_id,
        }
        if req.edit_engine:
            edit_body["engine"] = req.edit_engine
        edit_res = None
        async for kind, payload in _stage_with_heartbeat(
            _post_edit_api(client, "/edit", edit_body, _HTTP_TIMEOUT_EDIT_S),
            "edit",
        ):
            if kind == "heartbeat":
                yield payload
            elif kind == "error":
                log.warning("pipeline edit failed: %s", payload)
                yield _sse_event("stage_error", _stage_error_payload("edit", payload))
                yield _sse_event("pipeline_complete", {"request_id": request_id})
                return
            else:
                edit_res = payload

        edit_res = edit_res or {}
        image_url = edit_res.get("image_url")
        yield _sse_event(
            "stage_complete",
            {
                "stage": "edit",
                "engine": edit_res.get("engine"),
                "image_url": image_url,
                "image_format": edit_res.get("image_format"),
                "image_bytes": edit_res.get("image_bytes"),
                "metadata": edit_res.get("metadata", {}),
            },
        )

        # ---- Stage 4: VLM (review) -------------------------------------
        # review は決定的な失敗にしない。stage_error を吐いても pipeline_complete まで送る。
        yield _sse_event("stage_start", {"stage": "vlm_review"})
        if not image_url:
            yield _sse_event(
                "stage_error",
                {
                    "stage": "vlm_review",
                    "code": "missing_image_url",
                    "message": "edit response did not include image_url",
                },
            )
            yield _sse_event("pipeline_complete", {"request_id": request_id})
            return

        # AFTER 画像取得 → review POST。両方 heartbeat を回す。
        after_b64: Optional[str] = None
        async for kind, payload in _stage_with_heartbeat(
            _fetch_image_b64(client, image_url), "vlm_review"
        ):
            if kind == "heartbeat":
                yield payload
            elif kind == "error":
                log.warning("pipeline vlm_review fetch failed: %s", payload)
                yield _sse_event("stage_error", _stage_error_payload("vlm_review", payload))
                yield _sse_event("pipeline_complete", {"request_id": request_id})
                return
            else:
                after_b64 = payload

        review_body: dict[str, Any] = {
            "image_b64": after_b64 or "",
            "prompt": req.user_instruction,
            "mode": "review",
            "request_id": request_id,
        }
        if req.vlm_engine:
            review_body["engine"] = req.vlm_engine
        async for kind, payload in _stage_with_heartbeat(
            _post_edit_api(client, "/vlm", review_body, _HTTP_TIMEOUT_VLM_S),
            "vlm_review",
        ):
            if kind == "heartbeat":
                yield payload
            elif kind == "error":
                log.warning("pipeline vlm_review failed: %s", payload)
                yield _sse_event("stage_error", _stage_error_payload("vlm_review", payload))
                break
            else:
                review_res = payload or {}
                yield _sse_event(
                    "stage_complete",
                    {
                        "stage": "vlm_review",
                        "engine": review_res.get("engine"),
                        "text": review_res.get("text") or "",
                        "metadata": review_res.get("metadata", {}),
                    },
                )

        # ---- Stage 5 (optional): TTS readout of the review --------------
        # Only runs when the operator opts in via enable_tts. Non-fatal:
        # on failure we emit stage_error and still finish the pipeline.
        review_text = (review_res or {}).get("text") if "review_res" in locals() else None
        if req.enable_tts and review_text:
            yield _sse_event("stage_start", {"stage": "tts"})
            tts_body: dict[str, Any] = {"text": review_text, "request_id": request_id}
            if req.tts_engine:
                tts_body["engine"] = req.tts_engine
            async for kind, payload in _stage_with_heartbeat(
                _post_edit_api(client, "/tts", tts_body, _HTTP_TIMEOUT_VLM_S),
                "tts",
            ):
                if kind == "heartbeat":
                    yield payload
                elif kind == "error":
                    log.warning("pipeline tts failed: %s", payload)
                    yield _sse_event("stage_error", _stage_error_payload("tts", payload))
                    break
                else:
                    tts_res = payload or {}
                    yield _sse_event(
                        "stage_complete",
                        {
                            "stage": "tts",
                            "engine": tts_res.get("engine"),
                            "audio_url": tts_res.get("audio_url"),
                            "audio_format": tts_res.get("audio_format"),
                            "audio_bytes": tts_res.get("audio_bytes"),
                            "metadata": tts_res.get("metadata", {}),
                        },
                    )

        yield _sse_event("pipeline_complete", {"request_id": request_id})


@app.post("/stream/pipeline")
async def pipeline(req: PipelineRequest) -> StreamingResponse:
    if not req.image_b64 or not req.user_instruction:
        raise HTTPException(status_code=400, detail="image_b64 and user_instruction are required")
    return StreamingResponse(_run_pipeline(req), media_type="text/event-stream", headers=_pipeline_headers())


# ---------------------------------------------------------------------------
# /stream/generate: text-only generation pipeline (no input image)
# ---------------------------------------------------------------------------
# Two stages:
#   1) vlm_translate (optional): rewrite the user prompt as a concise English
#      image-gen prompt. Stability content-filters non-English prompts very
#      aggressively, returning an empty `images` payload with finish_reasons=
#      ["Filter reason: prompt"]. Routing through the VLM slot lets the
#      operator pick which engine does the rewrite — Bedrock Claude/Nova or
#      Trainium Qwen3-VL — so a Trainium demo can stay end-to-end on-device.
#      The translate step is skipped when the prompt is already mostly ASCII
#      (i.e. likely English), so an English-only flow stays single-stage.
#   2) generate: text -> image via the chosen GENERATE engine.
# stage names match frontend StageId:
#   stage_start vlm_translate -> stage_complete vlm_translate
#   stage_start generate      -> stage_complete generate


def _looks_english(text: str) -> bool:
    """Heuristic: skip translation when the input is already ~English.

    Counts how many characters are 7-bit ASCII. >=90% ASCII is taken as a
    cheap proxy for "no translation needed". Imperfect (e.g. an English
    sentence with a single emoji still scores 100%) but correct enough for
    a demo-time gate.
    """
    if not text:
        return True
    ascii_count = sum(1 for ch in text if ord(ch) < 128)
    return ascii_count / len(text) >= 0.9


class GeneratePipelineRequest(BaseModel):
    """Text-to-image pipeline input.

    Fields:
      - user_instruction: post-ASR (or directly typed) text used as the prompt.
      - vlm_engine:       optional override for the translate step.
      - generate_engine:  optional override for the image generator.
      - skip_translate:   force-disable the translate step even for non-English.
    """

    user_instruction: str = Field(..., min_length=1)
    vlm_engine: Optional[str] = None
    generate_engine: Optional[str] = None
    skip_translate: bool = False
    request_id: Optional[str] = None


async def _run_generate_pipeline(req: GeneratePipelineRequest) -> AsyncIterator[bytes]:
    request_id = req.request_id or str(uuid.uuid4())
    yield _sse_event("pipeline_start", {"request_id": request_id})

    if not _EDIT_API_BASE_URL or not _ORIGIN_VERIFY_HEADER_VALUE:
        yield _sse_event(
            "stage_error",
            {
                "stage": "config",
                "code": "config_missing",
                "message": "EDIT_API_BASE_URL / ORIGIN_VERIFY_HEADER_VALUE is not set",
            },
        )
        yield _sse_event("pipeline_complete", {"request_id": request_id})
        return

    async with httpx.AsyncClient(http2=False) as client:
        # ---- Stage 1: VLM (translate) ----------------------------------
        prompt_for_generator = req.user_instruction
        translated: Optional[str] = None
        do_translate = (
            not req.skip_translate and not _looks_english(req.user_instruction)
        )
        if do_translate:
            yield _sse_event("stage_start", {"stage": "vlm_translate"})
            vlm_body: dict[str, Any] = {
                "prompt": req.user_instruction,
                "mode": "translate",
                "request_id": request_id,
            }
            if req.vlm_engine:
                vlm_body["engine"] = req.vlm_engine
            vlm_res = None
            async for kind, payload in _stage_with_heartbeat(
                _post_edit_api(client, "/vlm", vlm_body, _HTTP_TIMEOUT_VLM_S),
                "vlm_translate",
            ):
                if kind == "heartbeat":
                    yield payload
                elif kind == "error":
                    # Translation is best-effort: log it, but fall back to
                    # the original prompt so the demo keeps working even if
                    # the chosen VLM is down.
                    log.warning("vlm_translate failed (using original): %s", payload)
                    yield _sse_event(
                        "stage_error", _stage_error_payload("vlm_translate", payload)
                    )
                    break
                else:
                    vlm_res = payload
            if vlm_res:
                translated = (vlm_res.get("text") or "").strip() or None
                if translated:
                    prompt_for_generator = translated
                yield _sse_event(
                    "stage_complete",
                    {
                        "stage": "vlm_translate",
                        "engine": vlm_res.get("engine"),
                        "text": translated or req.user_instruction,
                        "metadata": vlm_res.get("metadata", {}),
                    },
                )

        # ---- Stage 2: GENERATE -----------------------------------------
        yield _sse_event("stage_start", {"stage": "generate"})
        body: dict[str, Any] = {
            "prompt": prompt_for_generator,
            "request_id": request_id,
        }
        if req.generate_engine:
            body["engine"] = req.generate_engine
        gen_res = None
        async for kind, payload in _stage_with_heartbeat(
            _post_edit_api(client, "/generate", body, _HTTP_TIMEOUT_EDIT_S),
            "generate",
        ):
            if kind == "heartbeat":
                yield payload
            elif kind == "error":
                log.warning("pipeline generate failed: %s", payload)
                yield _sse_event("stage_error", _stage_error_payload("generate", payload))
                yield _sse_event("pipeline_complete", {"request_id": request_id})
                return
            else:
                gen_res = payload

        gen_res = gen_res or {}
        yield _sse_event(
            "stage_complete",
            {
                "stage": "generate",
                "engine": gen_res.get("engine"),
                "image_url": gen_res.get("image_url"),
                "image_format": gen_res.get("image_format"),
                "image_bytes": gen_res.get("image_bytes"),
                "metadata": gen_res.get("metadata", {}),
                "translated_prompt": translated,
            },
        )
        yield _sse_event("pipeline_complete", {"request_id": request_id})


@app.post("/stream/generate")
async def generate_pipeline(req: GeneratePipelineRequest) -> StreamingResponse:
    if not req.user_instruction:
        raise HTTPException(status_code=400, detail="user_instruction is required")
    return StreamingResponse(
        _run_generate_pipeline(req),
        media_type="text/event-stream",
        headers=_pipeline_headers(),
    )
