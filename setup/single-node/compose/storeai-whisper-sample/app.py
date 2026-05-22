"""
Phase E minimal sample: CPU Whisper-tiny FastAPI.

Listens on :8765, exposes /health (ALB target group health check) and
/api/whisper/transcribe (POST audio bytes → JSON {"text": ...}).

This is the smallest thing that makes the ALB Whisper TG go healthy
without engaging Trainium. NeuronCore inference is a later phase
(swap the model with optimum-neuron Whisper, no other changes).
"""
import io
import logging
import os

import torch
from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse
from transformers import pipeline

logging.basicConfig(level=logging.INFO)
log = logging.getLogger("storeai-whisper-sample")

MODEL_NAME = os.environ.get("WHISPER_MODEL", "openai/whisper-tiny")

app = FastAPI(title="storeai-whisper-sample", version="0.1.0")

asr = None


@app.on_event("startup")
def _load_model() -> None:
    global asr
    log.info("loading model: %s", MODEL_NAME)
    asr = pipeline(
        task="automatic-speech-recognition",
        model=MODEL_NAME,
        device=-1,
        torch_dtype=torch.float32,
    )
    log.info("model ready")


@app.get("/health")
def health() -> Response:
    if asr is None:
        return Response(content="loading", status_code=503)
    return JSONResponse({"status": "ok", "model": MODEL_NAME})


@app.get("/api/whisper/health")
def api_health() -> Response:
    return health()


@app.post("/api/whisper/transcribe")
async def transcribe(request: Request) -> JSONResponse:
    if asr is None:
        return JSONResponse({"error": "model not ready"}, status_code=503)
    body = await request.body()
    if not body:
        return JSONResponse({"error": "empty body"}, status_code=400)
    try:
        result = asr(io.BytesIO(body).read())
    except Exception as exc:
        log.exception("inference failed")
        return JSONResponse({"error": str(exc)}, status_code=500)
    text = result.get("text") if isinstance(result, dict) else str(result)
    return JSONResponse({"text": text})
