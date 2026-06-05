"""neuron-anatomy standalone FastAPI app.

Run via systemd (neuron-anatomy.service) using uvicorn. Other samples
that prefer to embed the router in their own FastAPI process can do:

    from neuron_anatomy import router
    app.include_router(router)

Environment variables:
  NEURON_ANATOMY_PORT             default: 8810 (handled at the systemd level)
  NEURON_MONITOR_BIN              default: /opt/aws/neuron/bin/neuron-monitor
  NEURON_LS_BIN                   default: /opt/aws/neuron/bin/neuron-ls
  NEURON_MONITOR_PERIOD_S         default: 1
  NEURON_ANATOMY_FAKE_MONITOR     "1" to emit a synthetic waveform locally
  NEURON_ANATOMY_FAKE_TOPOLOGY    "1" to use a synthetic neuron-ls payload
  NEURON_ANATOMY_FAKE_VARIANT     "trn2.3xlarge" or "trn2.48xlarge" (default)
  NEURON_ANATOMY_INCLUDE_RAW      "1" to include the raw neuron-monitor JSON
"""
from __future__ import annotations

import logging
import os
from contextlib import asynccontextmanager

from fastapi import FastAPI

from neuron_anatomy import router as neuron_anatomy_router
from neuron_anatomy.monitor import monitor_service
from neuron_anatomy.topology import topology_cache


LOG_LEVEL = os.environ.get("LOG_LEVEL", "INFO").upper()
logging.basicConfig(
    level=LOG_LEVEL,
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("neuron-anatomy")


@asynccontextmanager
async def lifespan(_app: FastAPI):
    # Prime the topology cache before the monitor starts so the first
    # snapshot already has chip groupings to roll up against.
    try:
        await topology_cache.get()
    except Exception:  # noqa: BLE001
        log.exception(
            "initial topology fetch failed; will retry on first /neuron/topology call"
        )
    await monitor_service.start()
    try:
        yield
    finally:
        await monitor_service.stop()


app = FastAPI(
    title="neuron-anatomy",
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
    lifespan=lifespan,
)
app.include_router(neuron_anatomy_router)


# Bare /health (without /neuron prefix) so the ALB health check can hit a
# minimal endpoint without dragging in topology/snapshot logic.
@app.get("/health")
async def root_health() -> dict[str, str]:
    return {"status": "ok"}
