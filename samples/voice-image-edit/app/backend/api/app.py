"""voice-image-edit /api/edit/* FastAPI service (port 8801)。

旧 ALB Lambda Target は request/response とも 1MB 上限があり、画像 pipeline
には構造的に合わなかった (Nova Canvas 1024px PNG が 1.5〜3 MB に達するため)。
P10 で Lambda を退役させ、frontend / stream と同じ EC2 上に systemd unit
(voice-image-edit-api.service) として常駐させる。

責務はルーティングと正規化のみ。3 スロット (ASR / VLM / EDIT) の処理は
それぞれの engines/ サブモジュールに閉じ込める (旧 Lambda 実装と同じ)。
ALB は IP target group → EC2:8801 で受け、X-Origin-Verify header の完全
一致を listener rule で要求する。

ルート:
  GET  /api/edit/health   -> ヘルスチェック (全スロット registry を一覧)
  GET  /api/edit/engines  -> スロット ✕ 実装の一覧 + 既定値
  POST /api/edit/asr      -> AsrRequest -> AsrResponse | EngineError
  POST /api/edit/vlm      -> VlmRequest -> VlmResponse | EngineError
  POST /api/edit/edit     -> EditRequest -> EditResponse | EngineError

EDIT スロットは依然として presigned URL 方式を維持する (P10 ユーザー指示)。
理由は、SSE 経由で巨大な base64 を流すとエラーハンドルが複雑になるのと、
将来動画など更に大きい payload を扱う際にも汎用的に効くため。
"""
from __future__ import annotations

import asyncio
import base64
import logging
import os
import uuid
from typing import Any

import boto3
import uvicorn
from botocore.config import Config as BotoConfig
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from contracts import AsrRequest, EditRequest, EngineError, VlmRequest
import engines as registry

LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("voice-image-edit-api")

# EDIT 結果を S3 に置いて presigned URL で返すための設定。env が無いと EDIT は使えない。
_EDIT_RESULT_BUCKET = os.environ.get("EDIT_RESULT_BUCKET", "")
_EDIT_RESULT_TTL = int(os.environ.get("EDIT_RESULT_TTL_SECONDS", "900"))
_EDIT_RESULT_PREFIX = os.environ.get("EDIT_RESULT_PREFIX", "edit-results/")
# boto3 client はプロセス起動時に 1 度だけ作る (uvicorn worker ごとの cold start 相当)。
# SigV4 (s3v4) を明示。STS 一時クレデンシャル (x-amz-security-token) で presigned URL を発行する場合、
# us-east-2 などの新しいリージョンは SigV4 のみ受け付け、SigV2 (AWSAccessKeyId=/Signature=) は 400 を返す。
_S3_REGION = (
    os.environ.get("EDIT_RESULT_REGION")
    or os.environ.get("AWS_REGION")
    or os.environ.get("AWS_DEFAULT_REGION")
    or None
)
_s3_client = (
    boto3.client(
        "s3",
        region_name=_S3_REGION,
        config=BotoConfig(signature_version="s3v4", s3={"addressing_style": "virtual"}),
    )
    if _EDIT_RESULT_BUCKET
    else None
)


app = FastAPI(
    title="voice-image-edit-api",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)


def _status_for(code: str) -> int:
    if code in {"invalid_request", "invalid_body", "invalid_image", "unknown_engine", "unknown_slot"}:
        return 400
    if code == "config_missing":
        return 503
    if code == "not_found":
        return 404
    if code == "not_implemented":
        return 501
    return 502


def _error_response(exc: EngineError) -> JSONResponse:
    return JSONResponse(status_code=_status_for(exc.code), content=exc.to_dict())


@app.get("/api/edit/health")
async def health() -> JSONResponse:
    return JSONResponse({"status": "ok", "slots": registry.list_all()})


@app.get("/api/edit/engines")
async def list_all_engines() -> JSONResponse:
    return JSONResponse({"slots": registry.list_all()})


async def _read_json(request: Request) -> dict[str, Any]:
    raw = await request.body()
    if not raw:
        return {}
    try:
        import json

        return json.loads(raw.decode("utf-8"))
    except (ValueError, UnicodeDecodeError) as exc:
        raise EngineError("invalid_body", f"invalid JSON: {exc}") from exc


@app.post("/api/edit/asr")
async def post_asr(request: Request) -> JSONResponse:
    try:
        body = await _read_json(request)
        req = AsrRequest.from_dict(body)
        engine = registry.get_engine("asr", req.engine)
        # uvicorn の running event loop 内で engine.invoke を呼ぶと、
        # 内部で asyncio.run(...) を使う実装 (Transcribe streaming 等) が
        # "asyncio.run() cannot be called from a running event loop" で
        # 死ぬ。to_thread で別スレッドに逃がせば、新スレッドの top-level
        # で asyncio.run を呼べるようになる (boto3 のブロッキング呼び出
        # しもこのまま逃げられて一石二鳥)。
        result = await asyncio.to_thread(engine.invoke, req)
        return JSONResponse(result.to_dict())
    except EngineError as exc:
        log.warning("asr engine error code=%s message=%s", exc.code, exc.message)
        return _error_response(exc)
    except Exception as exc:  # noqa: BLE001
        log.exception("asr unhandled exception")
        return JSONResponse(
            status_code=500,
            content={"error": {"code": "internal", "message": str(exc), "retryable": False}},
        )


@app.post("/api/edit/vlm")
async def post_vlm(request: Request) -> JSONResponse:
    try:
        body = await _read_json(request)
        req = VlmRequest.from_dict(body)
        engine = registry.get_engine("vlm", req.engine)
        result = await asyncio.to_thread(engine.invoke, req)
        return JSONResponse(result.to_dict())
    except EngineError as exc:
        log.warning("vlm engine error code=%s message=%s", exc.code, exc.message)
        return _error_response(exc)
    except Exception as exc:  # noqa: BLE001
        log.exception("vlm unhandled exception")
        return JSONResponse(
            status_code=500,
            content={"error": {"code": "internal", "message": str(exc), "retryable": False}},
        )


@app.post("/api/edit/edit")
async def post_edit(request: Request) -> JSONResponse:
    try:
        body = await _read_json(request)
        req = EditRequest.from_dict(body)
        engine = registry.get_engine("edit", req.engine)
        result = await asyncio.to_thread(engine.invoke, req)
        # _edit_to_presigned は同期 boto3 (put_object/generate_presigned_url) なので
        # こちらも別スレッドに逃がす。
        payload = await asyncio.to_thread(_edit_to_presigned, result.to_dict())
        return JSONResponse(payload)
    except EngineError as exc:
        log.warning("edit engine error code=%s message=%s", exc.code, exc.message)
        return _error_response(exc)
    except Exception as exc:  # noqa: BLE001
        log.exception("edit unhandled exception")
        return JSONResponse(
            status_code=500,
            content={"error": {"code": "internal", "message": str(exc), "retryable": False}},
        )


def _edit_to_presigned(payload: dict[str, Any]) -> dict[str, Any]:
    """EditResponse の image_b64 を S3 に put して presigned URL に差し替える。

    SSE / フロントエンドへの payload 肥大を避けるため、Nova Canvas 出力 PNG は
    短命 bucket (1 日 expire) に put し、presigned GET URL を返す。bucket /
    s3 client が無いときは config_missing で 503 を返す。

    旧 Lambda 版 lambda_function.py:_edit_to_presigned と同じ挙動。EC2 移行後
    も image_b64 を inline で返すと SSE のエラーハンドルが複雑になるため
    (P10 で presigned 方式維持の方針が確定)。
    """
    if not _EDIT_RESULT_BUCKET or _s3_client is None:
        raise EngineError(
            "config_missing",
            "EDIT_RESULT_BUCKET env var is required for EDIT slot",
        )
    image_b64 = payload.get("image_b64")
    if not image_b64:
        return payload
    try:
        image_bytes = base64.b64decode(image_b64)
    except (ValueError, TypeError) as exc:
        raise EngineError(
            "provider_invalid_response",
            f"engine returned non-base64 image: {exc}",
        ) from exc
    request_id = (payload.get("metadata") or {}).get("request_id") or str(uuid.uuid4())
    key = f"{_EDIT_RESULT_PREFIX}{request_id}.png"
    try:
        _s3_client.put_object(
            Bucket=_EDIT_RESULT_BUCKET,
            Key=key,
            Body=image_bytes,
            ContentType="image/png",
            CacheControl="no-store",
        )
        url = _s3_client.generate_presigned_url(
            "get_object",
            Params={"Bucket": _EDIT_RESULT_BUCKET, "Key": key},
            ExpiresIn=_EDIT_RESULT_TTL,
        )
    except Exception as exc:  # noqa: BLE001
        raise EngineError(
            "provider_error",
            f"failed to upload edit result to S3: {exc}",
            retryable=True,
        ) from exc
    out = {k: v for k, v in payload.items() if k != "image_b64"}
    out["image_url"] = url
    out["image_format"] = "png"
    out["image_bytes"] = len(image_bytes)
    return out


if __name__ == "__main__":
    # systemd unit (voice-image-edit-api.service) は ExecStart で
    #   {VENV}/bin/uvicorn app:app --host 0.0.0.0 --port {API_PORT} ...
    # を呼ぶため、本ブロックは local debug 用。
    port = int(os.environ.get("API_PORT", "8801"))
    uvicorn.run(app, host="0.0.0.0", port=port)
