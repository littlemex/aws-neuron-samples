"""Whisper Neuron transcription server (single-port HTTP + WebSocket).

Two interfaces over one aiohttp app:
- HTTP POST /transcribe         : batch (full audio in body)
- WebSocket /whisper-neuron/ws  : live streaming (16kHz int16 mono frames)

Both share the same pre-compiled Neuron artifacts. The HTTP path is the canonical
voice-image-edit ASR contract (engines/asr/trainium.py). The WebSocket path is
kept for parity with the original GPU live demo.

Pre-compiled artifacts must already exist under MODEL_DIR (compile_whisper.py).

Environment variables (no hardcoded paths):
    PORT                  default 8765
    PATH_PREFIX           default /whisper-neuron
    MODEL_DIR             default /models/whisper-large-v3-neuron
    MODEL_ID              default openai/whisper-large-v3
    WHISPER_LANGUAGE      ja | en | auto | none  (default ja)
    NEURON_RT_NUM_CORES   default 1

Audio decoding for /transcribe:
    The body MAY be raw PCM (int16 mono), WAV, MP3, OGG, WebM, FLAC, etc.
    soundfile (libsndfile) is tried first. If that fails (e.g. WebM/Opus from
    the browser), ffmpeg is invoked to transcode to 16 kHz int16 mono WAV.
"""
from __future__ import annotations

import asyncio
import io
import json
import os
import shutil
import subprocess
import sys
import threading
import time
import types

import numpy as np
import torch
import torch.nn.functional as F
import torch_neuronx
from aiohttp import web
from transformers import WhisperProcessor, WhisperForConditionalGeneration
from transformers.modeling_outputs import (
    BaseModelOutput,
    BaseModelOutputWithPastAndCrossAttentions,
)

os.environ.setdefault("NEURON_RT_NUM_CORES", "1")

MODEL_DIR = os.environ.get("MODEL_DIR", "/models/whisper-large-v3-neuron")
MODEL_ID = os.environ.get("MODEL_ID", "openai/whisper-large-v3")
SAMPLE_RATE = 16000
PORT = int(os.environ.get("PORT", "8765"))
PATH_PREFIX = os.environ.get("PATH_PREFIX", "/whisper-neuron")

# WHISPER_LANGUAGE_ENV_PATCH: handled natively. start.sh skips its legacy
# `language="en"` rewrite when this marker is present.
_LANG_RAW = os.environ.get("WHISPER_LANGUAGE", "ja").strip().lower()
WHISPER_LANGUAGE = None if _LANG_RAW in ("", "auto", "none") else _LANG_RAW

# Streaming-mode tunables (WebSocket path only)
MIN_CHUNK_SEC = 1.0
BUFFER_CAP_SEC = 45
BUFFER_TRIM_SEC = 30
SAME_OUTPUT_THRESHOLD = 7
VAD_THRESHOLD = 0.3

# Silero VAD is only required by the streaming path; load lazily so the HTTP
# /transcribe path stays usable even if the VAD download fails.
_vad_lock = threading.Lock()
_vad_state: dict = {"loaded": False, "model": None, "fn": None, "error": None}


def _ensure_vad_loaded() -> bool:
    if _vad_state["loaded"]:
        return _vad_state["model"] is not None
    with _vad_lock:
        if _vad_state["loaded"]:
            return _vad_state["model"] is not None
        try:
            print("[whisper-server] Loading Silero VAD...", flush=True)
            vad_model, vad_utils = torch.hub.load(
                "snakers4/silero-vad", "silero_vad", trust_repo=True
            )
            (get_speech_timestamps, _, _, _, _) = vad_utils
            _vad_state.update(
                loaded=True, model=vad_model, fn=get_speech_timestamps, error=None
            )
        except Exception as exc:
            _vad_state.update(loaded=True, model=None, fn=None, error=str(exc))
            print(f"[whisper-server] WARN: VAD load failed: {exc}", flush=True)
        return _vad_state["model"] is not None


def load_neuron_model():
    """Load Whisper with pre-compiled Neuron artifacts."""
    meta_path = os.path.join(MODEL_DIR, "compile_metadata.json")
    if not os.path.isfile(meta_path):
        raise RuntimeError(
            f"compile_metadata.json not found at {meta_path}. "
            "Run compile_whisper.py before starting the server."
        )
    with open(meta_path) as f:
        meta = json.load(f)

    batch_size = meta["batch_size"]
    max_dec_len = meta["max_dec_len"]
    suffix = meta["suffix"]
    output_attentions = meta.get("output_attentions", False)

    print(f"[whisper-server] Loading processor from {MODEL_DIR}...", flush=True)
    processor = WhisperProcessor.from_pretrained(MODEL_DIR)

    print(f"[whisper-server] Loading model weights from {MODEL_ID}...", flush=True)
    model = WhisperForConditionalGeneration.from_pretrained(MODEL_ID, torchscript=True)

    def enc_f(self, input_features, attention_mask=None, **kw):
        if attention_mask is None:
            attention_mask = torch.zeros(
                [input_features.shape[0], input_features.shape[1]], dtype=torch.int64
            )
        if hasattr(self, "forward_neuron"):
            out = self.forward_neuron(input_features, attention_mask)
        else:
            out = self.forward_(input_features, attention_mask, return_dict=True)
        return BaseModelOutput(**out)

    def dec_f(self, input_ids, attention_mask=None, encoder_hidden_states=None, **kw):
        if attention_mask is not None and encoder_hidden_states is None:
            encoder_hidden_states, attention_mask = attention_mask, encoder_hidden_states
        inp = [input_ids, encoder_hidden_states]
        pad = self.max_length - inp[0].shape[1]
        inp[0] = F.pad(inp[0], (0, pad), "constant", processor.tokenizer.pad_token_id)
        if hasattr(self, "forward_neuron"):
            out = self.forward_neuron(*inp)
        else:
            out = self.forward_(
                input_ids=inp[0],
                encoder_hidden_states=inp[1],
                return_dict=True,
                use_cache=False,
                output_attentions=output_attentions,
            )
        out["last_hidden_state"] = out["last_hidden_state"][:, : input_ids.shape[1], :]
        if out.get("attentions") is not None:
            out["attentions"] = torch.stack(
                [
                    torch.mean(
                        o[:, :, : input_ids.shape[1], : input_ids.shape[1]],
                        axis=2,
                        keepdim=True,
                    )
                    for o in out["attentions"]
                ]
            )
        if out.get("cross_attentions") is not None:
            out["cross_attentions"] = torch.stack(
                [
                    torch.mean(o[:, :, : input_ids.shape[1], :], axis=2, keepdim=True)
                    for o in out["cross_attentions"]
                ]
            )
        return BaseModelOutputWithPastAndCrossAttentions(**out)

    def proj_f(self, inp):
        pad = self.max_length - inp.shape[1]
        x = F.pad(inp, (0, 0, 0, pad), "constant", processor.tokenizer.pad_token_id)
        if hasattr(self, "forward_neuron"):
            out = self.forward_neuron(x)
        else:
            out = self.forward_(x)
        return out[:, : inp.shape[1], :]

    for attr, fn in [
        ("model.encoder", enc_f),
        ("model.decoder", dec_f),
        ("proj_out", proj_f),
    ]:
        obj = model
        for p in attr.split("."):
            obj = getattr(obj, p)
        if not hasattr(obj, "forward_"):
            obj.forward_ = obj.forward
        obj.forward = types.MethodType(fn, obj)

    model.model.decoder.max_length = max_dec_len
    model.proj_out.max_length = max_dec_len

    for name, path_fmt in [
        ("model.encoder", f"whisper_{suffix}_{batch_size}_neuron_encoder.pt"),
        ("model.decoder", f"whisper_{suffix}_{batch_size}_{max_dec_len}_neuron_decoder.pt"),
        ("proj_out", f"whisper_{suffix}_{batch_size}_{max_dec_len}_neuron_proj.pt"),
    ]:
        path = os.path.join(MODEL_DIR, path_fmt)
        print(f"[whisper-server] Loading compiled {name}: {path}", flush=True)
        obj = model
        for p in name.split("."):
            obj = getattr(obj, p)
        obj.forward_neuron = torch.jit.load(path)

    print("[whisper-server] Running warmup inference...", flush=True)
    torch.set_num_threads(1)
    _ = model.generate(
        torch.zeros([1, model.config.num_mel_bins, 3000], dtype=torch.float32),
        language=WHISPER_LANGUAGE,
    )
    print("[whisper-server] Warmup complete.", flush=True)
    return model, processor


print("[whisper-server] Loading Whisper Neuron model...", flush=True)
model, processor = load_neuron_model()
print(
    f"[whisper-server] Ready on :{PORT} "
    f"(http POST /transcribe, ws {PATH_PREFIX}/ws, language={WHISPER_LANGUAGE or 'auto'})",
    flush=True,
)

# Single global lock around model.generate() — Neuron torchscript artifacts
# are not safe to call concurrently from multiple threads.
_generate_lock = threading.Lock()


def _decode_audio(body: bytes, mime_type: str, sample_rate_hint: int | None) -> np.ndarray:
    """Decode an arbitrary audio body into float32 PCM at SAMPLE_RATE.

    Order of attempts:
      1. If mime_type indicates raw PCM int16, interpret directly using sample_rate_hint.
      2. soundfile (libsndfile) for WAV/FLAC/OGG.
      3. ffmpeg subprocess for everything else (WebM/Opus, MP3, etc).
    """
    mime_low = (mime_type or "").lower()

    # 1. Raw PCM int16
    if "pcm" in mime_low or mime_low in ("application/octet-stream",):
        rate = sample_rate_hint or SAMPLE_RATE
        audio = np.frombuffer(body, dtype=np.int16).astype(np.float32) / 32768.0
        if rate != SAMPLE_RATE:
            audio = _resample_linear(audio, rate, SAMPLE_RATE)
        return audio

    # 2. soundfile path
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

    # 3. ffmpeg fallback
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
        raise RuntimeError(f"ffmpeg decode failed: {proc.stderr[:512].decode('utf-8', 'replace')}")
    return np.frombuffer(proc.stdout, dtype=np.int16).astype(np.float32) / 32768.0


def _resample_linear(x: np.ndarray, src_rate: int, dst_rate: int) -> np.ndarray:
    if src_rate == dst_rate or x.size == 0:
        return x
    n_dst = int(round(x.shape[0] * dst_rate / src_rate))
    if n_dst <= 0:
        return np.zeros(0, dtype=x.dtype)
    src_t = np.linspace(0.0, 1.0, num=x.shape[0], endpoint=False)
    dst_t = np.linspace(0.0, 1.0, num=n_dst, endpoint=False)
    return np.interp(dst_t, src_t, x).astype(np.float32, copy=False)


def _transcribe_array(audio: np.ndarray, language: str | None) -> str:
    if audio.size == 0:
        return ""
    with torch.no_grad():
        features = processor(
            audio, sampling_rate=SAMPLE_RATE, return_tensors="pt"
        ).input_features
        with _generate_lock:
            ids = model.generate(features, language=language)
        text = processor.batch_decode(ids, skip_special_tokens=True)[0].strip()
    return text


# ----------------------------------------------------------------------------
# HTTP /transcribe — voice-image-edit ASR contract
# ----------------------------------------------------------------------------
async def transcribe_handler(request: web.Request) -> web.Response:
    body = await request.read()
    if not body:
        return web.json_response({"error": "empty body"}, status=400)
    mime = request.headers.get("X-Mime-Type", request.content_type or "application/octet-stream")
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


# ----------------------------------------------------------------------------
# WebSocket live streaming (kept from the original GPU demo)
# ----------------------------------------------------------------------------
class TranscriptionSession:
    def __init__(self, ws):
        self.ws = ws
        self.lock = threading.Lock()
        self.frames = None
        self.completed_text = ""
        self.exit = False
        self.loop = None

    def add_frames(self, chunk: np.ndarray):
        with self.lock:
            if self.frames is not None and self.frames.shape[0] > BUFFER_CAP_SEC * SAMPLE_RATE:
                trim = int(BUFFER_TRIM_SEC * SAMPLE_RATE)
                self.frames = self.frames[trim:]
            self.frames = (
                chunk.copy() if self.frames is None else np.concatenate((self.frames, chunk))
            )

    def _send(self, msg):
        if self.loop and not self.loop.is_closed():
            fut = asyncio.run_coroutine_threadsafe(self.ws.send_json(msg), self.loop)
            try:
                fut.result(timeout=5)
            except Exception as e:
                print(f"[whisper-server] ws send failed: {e}", flush=True)

    def transcribe_loop(self):
        prev_out = ""
        same_count = 0
        while not self.exit:
            try:
                with self.lock:
                    audio = self.frames.copy() if self.frames is not None else None
                if audio is None or len(audio) / SAMPLE_RATE < MIN_CHUNK_SEC:
                    time.sleep(0.1)
                    continue

                if _ensure_vad_loaded():
                    speech_ts = _vad_state["fn"](
                        torch.from_numpy(audio),
                        _vad_state["model"],
                        sampling_rate=SAMPLE_RATE,
                        threshold=VAD_THRESHOLD,
                    )
                    if not speech_ts:
                        time.sleep(0.2)
                        continue

                text = _transcribe_array(audio, language=WHISPER_LANGUAGE)
                if not text:
                    time.sleep(0.2)
                    continue

                new_text = text
                if self.completed_text and text.startswith(self.completed_text):
                    new_text = text[len(self.completed_text) :].strip()

                if new_text == prev_out and new_text:
                    same_count += 1
                    if same_count > SAME_OUTPUT_THRESHOLD:
                        self._send({"text": new_text, "completed": True})
                        self.completed_text = text
                        same_count = 0
                        prev_out = ""
                    else:
                        self._send({"text": new_text, "completed": False})
                else:
                    same_count = 0
                    if new_text:
                        self._send({"text": new_text, "completed": False})
                prev_out = new_text
                time.sleep(0.05)
            except Exception as e:
                print(f"[whisper-server] transcribe_loop error: {e}", flush=True)
                time.sleep(1)

        with self.lock:
            audio = self.frames.copy() if self.frames is not None else None
        if audio is not None and len(audio) / SAMPLE_RATE >= MIN_CHUNK_SEC:
            text = _transcribe_array(audio, language=WHISPER_LANGUAGE)
            remaining = (
                text[len(self.completed_text) :].strip()
                if self.completed_text and text.startswith(self.completed_text)
                else text
            )
            if remaining:
                self._send({"text": remaining, "completed": True})


async def websocket_handler(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse()
    await ws.prepare(request)
    print(f"[whisper-server] ws client connected: {request.remote}", flush=True)
    session = TranscriptionSession(ws)
    session.loop = asyncio.get_running_loop()
    t = threading.Thread(target=session.transcribe_loop, daemon=True)
    t.start()
    try:
        async for msg in ws:
            if msg.type == web.WSMsgType.BINARY:
                audio = np.frombuffer(msg.data, dtype=np.int16).astype(np.float32) / 32768.0
                session.add_frames(audio)
    finally:
        session.exit = True
        t.join(timeout=5)
        print(f"[whisper-server] ws client disconnected: {request.remote}", flush=True)
    return ws


async def health_handler(request: web.Request) -> web.Response:
    return web.json_response(
        {
            "status": "ok",
            "model": "large-v3",
            "backend": "neuron",
            "language": WHISPER_LANGUAGE or "auto",
            "model_dir": MODEL_DIR,
        }
    )


def build_app() -> web.Application:
    app = web.Application(client_max_size=200 * 1024 * 1024)
    # voice-image-edit ASR contract
    app.router.add_post("/transcribe", transcribe_handler)
    app.router.add_get("/health", health_handler)
    # legacy live-streaming routes (path-prefixed)
    app.router.add_get(f"{PATH_PREFIX}/health", health_handler)
    app.router.add_get(f"{PATH_PREFIX}/ws", websocket_handler)
    app.router.add_get(PATH_PREFIX, websocket_handler)
    return app


if __name__ == "__main__":
    web.run_app(build_app(), host="0.0.0.0", port=PORT)
