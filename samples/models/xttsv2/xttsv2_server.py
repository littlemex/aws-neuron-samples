"""XTTSv2 Neuron HTTP server (FastAPI / uvicorn).

Wraps the NeuronApplicationXTTSv2GPT coordinator behind the JSON HTTP
contract that voice-image-edit's TrainiumTtsEngine expects:

    POST /synthesize
      body : {"text": str, "voice"?: str, "language"?: str,
              "speed"?: float, "audio_format"?: str}
      out  : {"audio_b64": "<base64 wav>", "audio_format": "wav",
              "model_id": "xttsv2", "voice": str|null, "language": str|null}

    GET /health
      out  : {"status": "ok", "model": "xttsv2", "backend": "nxd_inference",
              "compiled_dir": "...", "model_dir": "..."}

Voice cloning lookup
--------------------
The ``voice`` field is treated as a directory name under ``XTTSV2_VOICES_DIR``
(default ``/models/xttsv2-voices``). Inside that directory we pass every
``*.wav`` file to XTTS as the speaker reference. If ``voice`` is omitted
or the directory has no wavs, we fall back to ``XTTSV2_DEFAULT_VOICE``
(default ``default``). Anyone wanting a new speaker just drops a wav into
``/models/xttsv2-voices/<name>/<anything>.wav`` — no server restart.

Environment
-----------
  COMPILED_MODEL_PATH   : compiled NEFF dir (must contain prefill/ + decode/)
  XTTS_MODEL_DIR        : XTTS-v2 checkpoint dir (model.pth + config.json)
  XTTSV2_VOICES_DIR     : root for speaker reference wavs (default /models/xttsv2-voices)
  XTTSV2_DEFAULT_VOICE  : default voice subdir name (default "default")
  XTTSV2_LANGUAGE       : default language code (default "ja")
  TP_DEGREE             : tp degree (must match compile; default 4)
  PORT                  : http port (default 8770)
"""
from __future__ import annotations

import base64
import io
import logging
import os
import re
import sys
import time
from contextlib import asynccontextmanager
from typing import Any, Optional

import numpy as np
import soundfile as sf
import torch
from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field

# neuron_xttsv2 lives next to this script.
_HERE = os.path.dirname(os.path.abspath(__file__))
if _HERE not in sys.path:
    sys.path.insert(0, _HERE)

# torchaudio 2.9 ships a torchcodec dependency that is missing on most
# Neuron AMIs; XTTS calls torchaudio.load to read speaker references.
# Replace it with a soundfile-backed shim so the demo does not require
# building torchcodec from source. Must run BEFORE importing TTS.
try:
    import torchaudio
    import torchaudio.functional as taf

    def _load_audio_via_soundfile(path, sr=None):
        wav, orig_sr = sf.read(path, dtype="float32", always_2d=True)
        wav_t = torch.from_numpy(wav.T)
        if sr and sr != orig_sr:
            wav_t = taf.resample(wav_t, orig_sr, sr)
            orig_sr = sr
        return wav_t, orig_sr

    torchaudio.load = _load_audio_via_soundfile  # type: ignore[assignment]
except ImportError:
    pass

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
log = logging.getLogger("xttsv2-server")


# ---------------------------------------------------------------------------
# Request / response models
# ---------------------------------------------------------------------------


class SynthesizeRequest(BaseModel):
    text: str = Field(..., min_length=1)
    voice: Optional[str] = None
    language: Optional[str] = None
    speed: Optional[float] = None  # accepted but XTTS does not natively support it; logged + ignored
    audio_format: Optional[str] = None  # "wav" only in v1


class SynthesizeResponse(BaseModel):
    audio_b64: str
    audio_format: str
    model_id: str
    voice: Optional[str]
    language: Optional[str]


# ---------------------------------------------------------------------------
# Server state
# ---------------------------------------------------------------------------


class _ServerState:
    cpu_model: Any = None         # TTS Xtts wrapper that owns HifiGAN / VQVAE / tokenizer
    coordinator: Any = None       # NeuronApplicationXTTSv2GPT
    xtts_cfg: Any = None
    voices_dir: str = ""
    default_voice: str = ""
    default_language: str = ""
    compiled_dir: str = ""
    model_dir: str = ""
    sample_rate: int = 24000      # XTTS HifiGAN output rate


STATE = _ServerState()


def _split_for_xtts(text: str, language: str) -> list[str]:
    """Split text into chunks XTTSv2 will not crash on.

    XTTSv2's GPT decoder asserts at 400 input tokens. The Coqui
    ``tokenizer.py`` exposes per-language soft character limits (71 for
    ``ja``, ~250 for ``en``) — we use those as the chunk budget. We
    first split on sentence terminators so cut points feel natural; any
    sentence still over the budget is then cut at clause-ish breaks
    (commas / spaces) and finally at a hard char window so a single
    un-punctuated paragraph still synthesises instead of asserting.
    """
    if not text:
        return [""]
    text = text.strip()
    # Per-language soft cap, mirrors Coqui's tokenizer table.
    soft_caps = {"ja": 60, "zh": 60, "ko": 60, "en": 200, "es": 200}
    cap = soft_caps.get(language, 200)
    if len(text) <= cap:
        return [text]

    # Sentence split first. We keep terminators with the preceding
    # sentence (look-behind) so playback still pauses naturally.
    sentences = [s.strip() for s in re.split(r"(?<=[。!?\.!\?])\s*", text) if s and s.strip()]
    chunks: list[str] = []
    for sent in sentences:
        if len(sent) <= cap:
            chunks.append(sent)
            continue
        # Sentence is too long on its own. Try clause-level breaks.
        parts = [p.strip() for p in re.split(r"[、,;]", sent) if p and p.strip()]
        buf = ""
        for part in parts:
            if not buf:
                buf = part
            elif len(buf) + 1 + len(part) <= cap:
                buf = f"{buf}, {part}" if part else buf
            else:
                chunks.append(buf)
                buf = part
        if buf:
            # Still too long? Hard window as the last resort.
            while len(buf) > cap:
                chunks.append(buf[:cap])
                buf = buf[cap:]
            if buf:
                chunks.append(buf)
    return chunks or [text[:cap]]


def _voice_speaker_wavs(voice_name: Optional[str]) -> list[str]:
    """Resolve a voice name to a list of speaker reference wav paths.

    Tries the requested voice first, then the configured default voice.
    Returns an empty list when no on-disk reference exists; the caller
    then falls back to a built-in speaker name from speakers_xtts.pth.
    """
    for name in [voice_name, STATE.default_voice]:
        if not name:
            continue
        d = os.path.join(STATE.voices_dir, name)
        if not os.path.isdir(d):
            continue
        wavs = sorted(
            os.path.join(d, f) for f in os.listdir(d)
            if f.lower().endswith((".wav", ".flac", ".mp3", ".ogg"))
        )
        if wavs:
            return wavs
    return []


def _builtin_speaker(voice_name: Optional[str]) -> Optional[str]:
    """Resolve a voice name to a built-in XTTSv2 speaker.

    Coqui ships ``speakers_xtts.pth`` (a dict keyed by speaker name) so
    XTTS can synthesise without an external reference WAV. We use it as
    the last-resort fallback when no on-disk voice reference is present.
    """
    speaker_manager = getattr(STATE.cpu_model, "speaker_manager", None)
    speakers = getattr(speaker_manager, "speakers", None) if speaker_manager else None
    if not speakers:
        return None
    if voice_name and voice_name in speakers:
        return voice_name
    if STATE.default_voice and STATE.default_voice in speakers:
        return STATE.default_voice
    # Stable pick: first speaker by sorted name.
    return sorted(speakers.keys())[0]


def _load_models() -> None:
    """Cold-start: load the CPU XTTS pipeline + the Neuron-traced GPT."""
    from TTS.tts.configs.xtts_config import XttsConfig
    from TTS.tts.models.xtts import Xtts

    from neuron_xttsv2.application_gpt import NeuronApplicationXTTSv2GPT
    from neuron_xttsv2.config import XTTSv2InferenceConfig
    from neuron_xttsv2.neuron_xttsv2 import NeuronGPT2InferenceModel
    from neuronx_distributed_inference.models.config import NeuronConfig

    compiled = os.environ["COMPILED_MODEL_PATH"]
    model_dir = os.environ["XTTS_MODEL_DIR"]
    tp_degree = int(os.environ.get("TP_DEGREE", "4"))
    seq_len = int(os.environ.get("XTTSV2_SEQ_LEN", "1081"))
    voices_dir = os.environ.get("XTTSV2_VOICES_DIR", "/models/xttsv2-voices")
    default_voice = os.environ.get("XTTSV2_DEFAULT_VOICE", "default")
    default_language = os.environ.get("XTTSV2_LANGUAGE", "ja")

    log.info("loading CPU XTTS pipeline from %s", model_dir)
    xtts_cfg = XttsConfig()
    xtts_cfg.load_json(os.path.join(model_dir, "config.json"))
    cpu_model = Xtts.init_from_config(xtts_cfg)
    cpu_model.load_checkpoint(xtts_cfg, checkpoint_dir=model_dir, eval=True)
    cpu_model.cpu()

    orig_gpt = cpu_model.gpt.gpt
    log.info("compiling/loading Neuron GPT (tp=%d, seq_len=%d)", tp_degree, seq_len)
    neuron_config = NeuronConfig(
        batch_size=1,
        tp_degree=tp_degree,
        seq_len=seq_len,
        torch_dtype=torch.bfloat16,
    )
    config = XTTSv2InferenceConfig(neuron_config=neuron_config)

    coordinator = NeuronApplicationXTTSv2GPT(model_path=compiled, config=config)
    coordinator.load(compiled, skip_warmup=False)
    coordinator.load_weights(os.path.join(model_dir, "model.pth"), tp_degree=tp_degree)

    # Forward override: replace the CPU GPT with a wrapper that delegates
    # the heavy decoder pass to Neuron. The CPU side still runs the
    # ConditioningEncoder, mel decoder, HifiGAN, and tokenisation.
    gpt_module = cpu_model.gpt
    gpt_module.gpt_inference = NeuronGPT2InferenceModel(
        gpt_config=orig_gpt.config,
        neuron_gpt_app=coordinator,
        mel_pos_emb=gpt_module.mel_pos_embedding,
        mel_emb=gpt_module.mel_embedding,
        final_norm=gpt_module.final_norm,
        mel_head=gpt_module.mel_head,
        gpt_ln_f=orig_gpt.ln_f,
        gpt_wpe=orig_gpt.wpe,
    )

    STATE.cpu_model = cpu_model
    STATE.coordinator = coordinator
    STATE.xtts_cfg = xtts_cfg
    STATE.voices_dir = voices_dir
    STATE.default_voice = default_voice
    STATE.default_language = default_language
    STATE.compiled_dir = compiled
    STATE.model_dir = model_dir
    log.info("XTTSv2 ready (compiled=%s, voices=%s)", compiled, voices_dir)


def _reset_kv_cache() -> None:
    """Reset the KV cache before every synthesis call.

    Without this the second and following requests inherit stale prefix
    state and the audio degrades into garbage; this is the documented
    workaround from the upstream XTTSv2-NxD experiment.
    """
    gpt_inference = STATE.cpu_model.gpt.gpt_inference
    gpt_inference.token_count = 0
    gpt_inference.cached_prefix_emb = None
    gpt_inference.is_prefill = True


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------


@asynccontextmanager
async def lifespan(_: FastAPI):
    _load_models()
    yield


app = FastAPI(title="xttsv2-server", version="1.0.0", lifespan=lifespan)


@app.get("/health")
def health() -> dict[str, Any]:
    return {
        "status": "ok",
        "model": "xttsv2",
        "backend": "nxd_inference",
        "compiled_dir": STATE.compiled_dir,
        "model_dir": STATE.model_dir,
        "voices_dir": STATE.voices_dir,
        "default_voice": STATE.default_voice,
        "default_language": STATE.default_language,
    }


@app.post("/synthesize", response_model=SynthesizeResponse)
def synthesize(req: SynthesizeRequest) -> SynthesizeResponse:
    if STATE.cpu_model is None:
        raise HTTPException(status_code=503, detail="model not loaded yet")

    audio_format = (req.audio_format or "wav").lower()
    if audio_format != "wav":
        raise HTTPException(
            status_code=400,
            detail=f"unsupported audio_format: {audio_format} (only 'wav' is supported)",
        )
    if req.speed and abs(req.speed - 1.0) > 1e-3:
        log.info("speed=%.2f requested but XTTS does not support it; ignoring", req.speed)

    language = req.language or STATE.default_language
    speaker_wavs = _voice_speaker_wavs(req.voice)
    speaker_name = None if speaker_wavs else _builtin_speaker(req.voice)

    _reset_kv_cache()

    if not speaker_wavs and not speaker_name:
        raise HTTPException(
            status_code=400,
            detail=(
                f"no speaker reference available for voice='{req.voice}'. "
                f"Drop a wav into {STATE.voices_dir}/<voice>/ or pick a name "
                f"from speakers_xtts.pth."
            ),
        )

    extra_kwargs: dict[str, Any] = {
        "gpt_cond_len": 3,
        "temperature": float(os.environ.get("XTTSV2_TEMPERATURE", "0.65")),
    }
    if speaker_name:
        extra_kwargs["speaker_id"] = speaker_name

    # XTTSv2's GPT decoder asserts at 400 input tokens. The Coqui JA
    # tokenizer hits that ceiling between roughly 70 and 150 source
    # characters (varies with the glyph mix), so anything that runs over
    # the warning threshold has to be split into shorter pieces and
    # concatenated. We split on sentence terminators first, then fall
    # back to a hard char window so a single un-punctuated paragraph
    # still completes instead of crashing the model.
    chunks = _split_for_xtts(req.text, language)
    t_start = time.monotonic()
    try:
        wav_pieces: list[Any] = []
        for chunk in chunks:
            out = STATE.cpu_model.synthesize(
                chunk,
                STATE.xtts_cfg,
                speaker_wavs or None,
                language,
                **extra_kwargs,
            )
            wav_pieces.append(out["wav"])
    except Exception as exc:
        log.exception("synthesize failed")
        raise HTTPException(status_code=500, detail=f"synthesize failed: {exc}") from exc

    elapsed = time.monotonic() - t_start

    if len(wav_pieces) == 1:
        wav = wav_pieces[0]
    else:
        # Insert a short silence between chunks so the joined audio does
        # not sound like a single rushed run-on. 120 ms at the model's
        # native sample rate keeps the cadence natural.
        gap = np.zeros(int(STATE.sample_rate * 0.12), dtype=np.float32)
        joined: list[Any] = []
        for i, piece in enumerate(wav_pieces):
            arr = piece if isinstance(piece, np.ndarray) else np.asarray(piece)
            if arr.dtype != np.float32:
                arr = arr.astype(np.float32)
            joined.append(arr)
            if i < len(wav_pieces) - 1:
                joined.append(gap)
        wav = np.concatenate(joined)
    buf = io.BytesIO()
    sf.write(buf, wav, STATE.sample_rate, format="WAV", subtype="PCM_16")
    audio_bytes = buf.getvalue()
    audio_b64 = base64.b64encode(audio_bytes).decode("ascii")
    log.info(
        "synthesize ok lang=%s voice=%s text_chars=%d chunks=%d audio_bytes=%d "
        "audio_seconds=%.2f wall_seconds=%.2f rtf=%.2f",
        language, req.voice or STATE.default_voice, len(req.text), len(chunks),
        len(audio_bytes), len(wav) / STATE.sample_rate,
        elapsed, (len(wav) / STATE.sample_rate) / max(elapsed, 1e-3),
    )

    return SynthesizeResponse(
        audio_b64=audio_b64,
        audio_format="wav",
        model_id="xttsv2",
        voice=req.voice or STATE.default_voice,
        language=language,
    )


if __name__ == "__main__":
    # systemd unit (xttsv2-server.service) launches uvicorn directly;
    # this block is only for ad-hoc local debugging.
    import uvicorn

    uvicorn.run(
        app,
        host="0.0.0.0",
        port=int(os.environ.get("PORT", "8770")),
    )
