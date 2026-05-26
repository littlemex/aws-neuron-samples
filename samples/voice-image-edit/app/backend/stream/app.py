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
    """4 段パイプラインの入力。

    - image_b64: BEFORE 画像 (base64 / data URL prefix なし)
    - user_instruction: ユーザー指示テキスト (ASR 後 or 直接入力)
    - vlm_engine / edit_engine: optional override (None なら server default)
    - request_id: なければ stream backend 側で発番する
    """

    image_b64: str = Field(..., min_length=1)
    user_instruction: str = Field(..., min_length=1)
    vlm_engine: Optional[str] = None
    edit_engine: Optional[str] = None
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
        yield _sse_event("stage_start", {"stage": "vlm_instruction"})
        try:
            vlm_body: dict[str, Any] = {
                "image_b64": req.image_b64,
                "prompt": req.user_instruction,
                "mode": "instruction",
                "request_id": request_id,
            }
            if req.vlm_engine:
                vlm_body["engine"] = req.vlm_engine
            vlm_res = await _post_edit_api(client, "/vlm", vlm_body, _HTTP_TIMEOUT_VLM_S)
        except Exception as exc:  # noqa: BLE001
            log.warning("pipeline vlm_instruction failed: %s", exc)
            yield _sse_event("stage_error", _stage_error_payload("vlm_instruction", exc))
            yield _sse_event("pipeline_complete", {"request_id": request_id})
            return

        edit_prompt = vlm_res.get("text") or ""
        yield _sse_event(
            "stage_complete",
            {
                "stage": "vlm_instruction",
                "engine": vlm_res.get("engine"),
                "text": edit_prompt,
                "metadata": vlm_res.get("metadata", {}),
            },
        )

        # ---- Stage 3: EDIT ----------------------------------------------
        yield _sse_event("stage_start", {"stage": "edit"})
        try:
            edit_body: dict[str, Any] = {
                "image_b64": req.image_b64,
                "prompt": edit_prompt,
                "request_id": request_id,
            }
            if req.edit_engine:
                edit_body["engine"] = req.edit_engine
            edit_res = await _post_edit_api(client, "/edit", edit_body, _HTTP_TIMEOUT_EDIT_S)
        except Exception as exc:  # noqa: BLE001
            log.warning("pipeline edit failed: %s", exc)
            yield _sse_event("stage_error", _stage_error_payload("edit", exc))
            yield _sse_event("pipeline_complete", {"request_id": request_id})
            return

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

        try:
            # P10 で /api/edit/* が EC2 systemd FastAPI に移ったので body 上限はなくなった。
            # AFTER 画像 (Nova Canvas 1024px PNG) をそのまま base64 で review に渡す。
            after_b64 = await _fetch_image_b64(client, image_url)
            review_body: dict[str, Any] = {
                "image_b64": after_b64,
                "prompt": req.user_instruction,
                "mode": "review",
                "request_id": request_id,
            }
            if req.vlm_engine:
                review_body["engine"] = req.vlm_engine
            review_res = await _post_edit_api(client, "/vlm", review_body, _HTTP_TIMEOUT_VLM_S)
            yield _sse_event(
                "stage_complete",
                {
                    "stage": "vlm_review",
                    "engine": review_res.get("engine"),
                    "text": review_res.get("text") or "",
                    "metadata": review_res.get("metadata", {}),
                },
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("pipeline vlm_review failed: %s", exc)
            yield _sse_event("stage_error", _stage_error_payload("vlm_review", exc))

        yield _sse_event("pipeline_complete", {"request_id": request_id})


@app.post("/stream/pipeline")
async def pipeline(req: PipelineRequest) -> StreamingResponse:
    if not req.image_b64 or not req.user_instruction:
        raise HTTPException(status_code=400, detail="image_b64 and user_instruction are required")
    return StreamingResponse(_run_pipeline(req), media_type="text/event-stream", headers=_pipeline_headers())
