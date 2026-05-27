"""共通: EngineMetadata の組み立て。

``latency_ms`` は ``time.monotonic()`` の差分から ms に換算。``request_id`` が None なら
新しい uuid4 を発行する (UI が明示的に発行していない初回呼び出しのため)。
"""
from __future__ import annotations

import time
import uuid
from typing import Any

from contracts import EngineMetadata


def build_metadata(
    *,
    model_id: str,
    start_monotonic: float,
    request_id: str | None,
    extra: dict[str, Any] | None = None,
) -> EngineMetadata:
    return EngineMetadata(
        model_id=model_id,
        latency_ms=int((time.monotonic() - start_monotonic) * 1000),
        request_id=request_id or str(uuid.uuid4()),
        extra=extra or {},
    )
