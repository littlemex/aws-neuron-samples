"""FastAPI APIRouter (prefix="/neuron").

Endpoints:
  GET /neuron/health        : monitor process status, last snapshot age
  GET /neuron/topology      : static topology read on startup (chips, edges, specs)
  GET /neuron/snapshot      : latest single Snapshot (polling fallback)
  GET /neuron/stream        : SSE feed (one Snapshot per period)

Notes:
  - Runs as its own systemd unit alongside voice-image-edit-stream, with no
    shared state. They are independent services.
  - SSE responses set X-Accel-Buffering: no and Cache-Control: no-cache so
    CloudFront and ALB do not buffer keep-alive comments. This mirrors the
    voice-image-edit-stream behaviour.
  - Heartbeats are SSE comment frames (": hb\n\n") emitted every
    _HEARTBEAT_INTERVAL_S seconds when no snapshot is available, so the
    ALB 60 s idle timer does not drop the connection.
"""
from __future__ import annotations

import asyncio
import json
import logging
import time
from typing import AsyncIterator

from fastapi import APIRouter
from fastapi.responses import JSONResponse, StreamingResponse

from .monitor import monitor_service
from .schemas import HealthResponse, Snapshot, TopologyResponse
from .topology import topology_cache

log = logging.getLogger("neuron-anatomy.router")

router = APIRouter(prefix="/neuron", tags=["neuron-anatomy"])


_HEARTBEAT_INTERVAL_S = 10.0
_SSE_HEADERS = {
    "Cache-Control": "no-cache, no-transform",
    "X-Accel-Buffering": "no",
    "Content-Type": "text/event-stream; charset=utf-8",
}


def _sse_data(event: str, payload: dict | str) -> bytes:
    body = (
        payload
        if isinstance(payload, str)
        else json.dumps(payload, separators=(",", ":"), ensure_ascii=False)
    )
    return f"event: {event}\ndata: {body}\n\n".encode("utf-8")


def _sse_comment(text: str) -> bytes:
    return f": {text}\n\n".encode("utf-8")


@router.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    instance_type = (
        topology_cache._cached.instance_type if topology_cache._cached else None
    )
    return HealthResponse(
        status="ok",
        monitor_running=monitor_service.is_running(),
        last_snapshot_age_ms=monitor_service.last_update_age_ms(),
        instance_type=instance_type,
    )


@router.get("/topology", response_model=TopologyResponse)
async def topology() -> TopologyResponse:
    return await topology_cache.get()


@router.get("/snapshot")
async def snapshot() -> JSONResponse:
    """Return the latest snapshot once. Polling fallback when SSE is unavailable."""
    snap = await monitor_service.latest()
    if snap is None:
        return JSONResponse(
            {"available": False, "ts_ms": int(time.time() * 1000)}, status_code=200
        )
    return JSONResponse(json.loads(snap.model_dump_json()))


@router.get("/stream")
async def stream() -> StreamingResponse:
    queue = monitor_service.subscribe()

    async def gen() -> AsyncIterator[bytes]:
        # Send the most recent snapshot immediately so the UI does not
        # appear blank during the first sample period.
        snap = await monitor_service.latest()
        if snap is not None:
            yield _sse_data("snapshot", json.loads(snap.model_dump_json()))

        try:
            while True:
                try:
                    next_snap: Snapshot = await asyncio.wait_for(
                        queue.get(), timeout=_HEARTBEAT_INTERVAL_S
                    )
                except asyncio.TimeoutError:
                    yield _sse_comment("hb")
                    continue
                yield _sse_data("snapshot", json.loads(next_snap.model_dump_json()))
        except asyncio.CancelledError:
            raise
        finally:
            monitor_service.unsubscribe(queue)

    return StreamingResponse(gen(), media_type="text/event-stream", headers=_SSE_HEADERS)
