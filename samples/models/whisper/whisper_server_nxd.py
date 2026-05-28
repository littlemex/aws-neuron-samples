"""Whisper Neuron transcription server backed by NxD Inference.

Replaces the legacy whisper_server.py (torch_neuronx.trace approach) with
``neuronx_distributed_inference``'s ``NeuronApplicationWhisper``. The HTTP
contract is unchanged so the voice-image-edit ``engines/asr/trainium.py``
caller does not need to be touched.

Endpoints:
    POST /transcribe              — voice-image-edit ASR contract
    GET  /health                  — liveness
    GET  /whisper-neuron/health   — same, path-prefixed for parity

Environment variables:
    PORT                  default 8765
    PATH_PREFIX           default /whisper-neuron
    MODEL_DIR             default /models/whisper-large-v3-neuron-nxd
    WHISPER_LANGUAGE      ja | en | auto | none  (default ja)
    NEURON_RT_NUM_CORES   default 8 (matches default tp_degree)

Audio decoding:
    The body MAY be raw PCM (int16 mono), WAV, MP3, OGG, WebM, FLAC, etc.
    soundfile (libsndfile) is tried first; ffmpeg is the fallback.
"""
from __future__ import annotations

import io
import json
import os
import shutil
import subprocess
import tempfile
import threading
import time

import numpy as np
import torch
from aiohttp import web

from neuronx_distributed_inference.models.config import NeuronConfig
from neuronx_distributed_inference.models.whisper.modeling_whisper import (
    NeuronApplicationWhisper,
    WhisperInferenceConfig,
)
from neuronx_distributed_inference.utils.hf_adapter import load_pretrained_config

os.environ.setdefault("NEURON_RT_NUM_CORES", "8")

MODEL_DIR = os.environ.get("MODEL_DIR", "/models/whisper-large-v3-neuron-nxd")
SAMPLE_RATE = 16000
PORT = int(os.environ.get("PORT", "8765"))
PATH_PREFIX = os.environ.get("PATH_PREFIX", "/whisper-neuron")

_LANG_RAW = os.environ.get("WHISPER_LANGUAGE", "ja").strip().lower()
WHISPER_LANGUAGE = None if _LANG_RAW in ("", "auto", "none") else _LANG_RAW

_DTYPE_MAP = {"fp16": torch.float16, "fp32": torch.float32}


def _load_metadata() -> dict:
    meta_path = os.path.join(MODEL_DIR, "compile_metadata.json")
    if not os.path.isfile(meta_path):
        raise RuntimeError(
            f"compile_metadata.json not found at {meta_path}. "
            "Run compile_whisper_nxd.py first."
        )
    with open(meta_path) as f:
        return json.load(f)


def load_neuron_model() -> NeuronApplicationWhisper:
    meta = _load_metadata()
    model_id = meta["model_id"]
    tp_degree = int(meta.get("tp_degree", 8))
    batch_size = int(meta.get("batch_size", 1))
    dtype = _DTYPE_MAP[meta.get("dtype", "fp16")]

    print(
        f"[whisper-server-nxd] model_id={model_id} tp={tp_degree} "
        f"batch={batch_size} dtype={meta.get('dtype', 'fp16')}",
        flush=True,
    )

    print("[whisper-server-nxd] Resolving HF checkpoint...", flush=True)
    if os.path.isdir(model_id):
        model_path = model_id
    else:
        from huggingface_hub import snapshot_download
        model_path = snapshot_download(repo_id=model_id)

    neuron_config = NeuronConfig(
        batch_size=batch_size,
        torch_dtype=dtype,
        tp_degree=tp_degree,
    )
    inference_config = WhisperInferenceConfig(
        neuron_config,
        load_config=load_pretrained_config(model_path),
    )

    print("[whisper-server-nxd] Instantiating NeuronApplicationWhisper...", flush=True)
    neuron_model = NeuronApplicationWhisper(model_path, config=inference_config)

    print(f"[whisper-server-nxd] Loading compiled artifacts from {MODEL_DIR}...", flush=True)
    neuron_model.load(MODEL_DIR)

    print("[whisper-server-nxd] Warmup transcribe (silence)...", flush=True)
    silence = np.zeros(SAMPLE_RATE, dtype=np.float32)
    with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as tmp:
        wav_path = tmp.name
    try:
        import soundfile as sf
        sf.write(wav_path, silence, SAMPLE_RATE)
        try:
            neuron_model.transcribe(
                wav_path,
                language=WHISPER_LANGUAGE,
                task="transcribe",
                fp16=(dtype == torch.float16),
                verbose=False,
            )
        except Exception as exc:
            print(f"[whisper-server-nxd] Warmup raised (non-fatal): {exc}", flush=True)
    finally:
        try:
            os.unlink(wav_path)
        except OSError:
            pass
    print("[whisper-server-nxd] Warmup complete.", flush=True)
    return neuron_model


print("[whisper-server-nxd] Loading model...", flush=True)
MODEL = load_neuron_model()
DTYPE_STR = _load_metadata().get("dtype", "fp16")
print(
    f"[whisper-server-nxd] Ready on :{PORT} "
    f"(http POST /transcribe, language={WHISPER_LANGUAGE or 'auto'})",
    flush=True,
)

# NxD's transcribe path is not safe to call concurrently from multiple threads.
_generate_lock = threading.Lock()


def _resample_linear(x: np.ndarray, src_rate: int, dst_rate: int) -> np.ndarray:
    if src_rate == dst_rate or x.size == 0:
        return x
    n_dst = int(round(x.shape[0] * dst_rate / src_rate))
    if n_dst <= 0:
        return np.zeros(0, dtype=x.dtype)
    src_t = np.linspace(0.0, 1.0, num=x.shape[0], endpoint=False)
    dst_t = np.linspace(0.0, 1.0, num=n_dst, endpoint=False)
    return np.interp(dst_t, src_t, x).astype(np.float32, copy=False)


def _decode_audio(body: bytes, mime_type: str, sample_rate_hint: int | None) -> np.ndarray:
    mime_low = (mime_type or "").lower()

    if "pcm" in mime_low or mime_low in ("application/octet-stream",):
        rate = sample_rate_hint or SAMPLE_RATE
        audio = np.frombuffer(body, dtype=np.int16).astype(np.float32) / 32768.0
        if rate != SAMPLE_RATE:
            audio = _resample_linear(audio, rate, SAMPLE_RATE)
        return audio

    try:
        import soundfile as sf  # type: ignore

        with io.BytesIO(body) as bio:
            data, rate = sf.read(bio, dtype="float32", always_2d=False)
        if data.ndim == 2:
            data = data.mean(axis=1)
        if rate != SAMPLE_RATE:
            data = _resample_linear(data, rate, SAMPLE_RATE)
        return data.astype(np.float32, copy=False)
    except Exception:
        pass

    if not shutil.which("ffmpeg"):
        raise RuntimeError("ffmpeg not found and soundfile decode failed")
    proc = subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error",
            "-i", "pipe:0",
            "-f", "s16le", "-ac", "1", "-ar", str(SAMPLE_RATE),
            "pipe:1",
        ],
        input=body,
        capture_output=True,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"ffmpeg decode failed: {proc.stderr[:512].decode('utf-8', 'replace')}"
        )
    return np.frombuffer(proc.stdout, dtype=np.int16).astype(np.float32) / 32768.0


def _transcribe_array(audio: np.ndarray, language: str | None) -> str:
    if audio.size == 0:
        return ""
    # NxD's transcribe accepts numpy/torch tensors or file paths. Use a tensor
    # to avoid the round-trip through the disk.
    audio_t = torch.from_numpy(audio.astype(np.float32, copy=False))
    fp16 = DTYPE_STR == "fp16"
    with torch.no_grad():
        with _generate_lock:
            result = MODEL.transcribe(
                audio_t,
                language=language,
                task="transcribe",
                fp16=fp16,
                verbose=False,
            )
    text = result.get("text", "") if isinstance(result, dict) else ""
    return text.strip()


async def transcribe_handler(request: web.Request) -> web.Response:
    body = await request.read()
    if not body:
        return web.json_response({"error": "empty body"}, status=400)
    mime = request.headers.get(
        "X-Mime-Type", request.content_type or "application/octet-stream"
    )
    rate_hdr = request.headers.get("X-Sample-Rate")
    try:
        sample_rate_hint = int(rate_hdr) if rate_hdr else None
    except ValueError:
        sample_rate_hint = None
    language = request.headers.get("X-Language") or WHISPER_LANGUAGE

    t0 = time.monotonic()
    try:
        audio = _decode_audio(body, mime, sample_rate_hint)
        text = _transcribe_array(audio, language=language)
    except Exception as exc:
        return web.json_response(
            {"error": "transcription failed", "detail": str(exc)}, status=500
        )

    elapsed_ms = int((time.monotonic() - t0) * 1000)
    duration_ms = int(audio.shape[0] / SAMPLE_RATE * 1000) if audio.size else 0
    return web.json_response(
        {
            "text": text,
            "segments": [
                {"start_ms": 0, "end_ms": duration_ms, "text": text},
            ],
            "language": language or "auto",
            "duration_ms": duration_ms,
            "latency_ms": elapsed_ms,
        }
    )


async def health_handler(request: web.Request) -> web.Response:
    return web.json_response(
        {
            "status": "ok",
            "model": "large-v3",
            "backend": "nxd_inference",
            "language": WHISPER_LANGUAGE or "auto",
            "model_dir": MODEL_DIR,
        }
    )


def build_app() -> web.Application:
    app = web.Application(client_max_size=200 * 1024 * 1024)
    app.router.add_post("/transcribe", transcribe_handler)
    app.router.add_get("/health", health_handler)
    app.router.add_get(f"{PATH_PREFIX}/health", health_handler)
    return app


if __name__ == "__main__":
    web.run_app(build_app(), host="0.0.0.0", port=PORT)
