"""HTTP status → EngineError 正規化。

5xx は retryable=True の provider_error。4xx の扱いは呼び出し側の選択 (旧 ASR/VLM は
``provider_invalid_response``、EDIT は ``provider_error`` に分岐していた経緯があるため、
``four_xx_code`` 引数で切替可能にしてある)。
"""
from __future__ import annotations

from typing import Any, Literal, Protocol

from contracts import EngineError


class _HttpResp(Protocol):
    status: int
    data: bytes


def safe_decode(b: bytes, limit: int = 512) -> str:
    return b[:limit].decode("utf-8", "replace")


def raise_for_status(
    resp: _HttpResp,
    *,
    label: str,
    four_xx_code: Literal["provider_error", "provider_invalid_response"] = "provider_invalid_response",
    extra_detail: dict[str, Any] | None = None,
) -> None:
    """``resp.status`` を見て、必要なら EngineError を raise する。

    - 5xx → ``provider_error`` retryable=True
    - 4xx → ``four_xx_code`` で指定したコード (default: provider_invalid_response)
    """
    if resp.status >= 500:
        raise EngineError(
            "provider_error",
            f"{label} returned {resp.status}",
            retryable=True,
            provider_detail={
                "status": resp.status,
                "body": safe_decode(resp.data),
                **(extra_detail or {}),
            },
        )
    if resp.status >= 400:
        raise EngineError(
            four_xx_code,
            f"{label} returned {resp.status}",
            retryable=False,
            provider_detail={
                "status": resp.status,
                "body": safe_decode(resp.data),
                **(extra_detail or {}),
            },
        )
