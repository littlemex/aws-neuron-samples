"""neuron-anatomy: backend for live visualisation of Trainium hardware.

Distributed as a pip-installable package. The standalone deployment runs
``main.py`` under uvicorn, but other samples can mount the router directly
into their own FastAPI app via ``app.include_router(router)``.

Public API:
    - router            : FastAPI APIRouter (prefix="/neuron")
    - schemas           : pydantic models that frontend mirrors in TypeScript
    - monitor.Snapshot  : single neuron-monitor sample, post-normalisation
    - topology.Topology : neuron-ls -j cache
"""
from __future__ import annotations

from . import schemas
from .router import router

__all__ = ["router", "schemas"]
