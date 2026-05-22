# Phase E minimal: CPU-only Whisper-tiny sample.
# Switches to optimum-neuron / NxDI in a later phase (FROM line + a single
# import change is the only delta).
FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    HF_HOME=/cache/hf \
    TRANSFORMERS_CACHE=/cache/hf \
    WHISPER_MODEL=openai/whisper-tiny

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg curl \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# Pinned to versions known to work with whisper-tiny on CPU.
RUN pip install --upgrade pip \
    && pip install \
        "fastapi==0.118.0" \
        "uvicorn[standard]==0.32.0" \
        "transformers==4.45.2" \
        "torch==2.4.1" \
        "torchaudio==2.4.1" \
        "soundfile==0.12.1" \
        "librosa==0.10.2.post1"

COPY app.py /app/app.py

EXPOSE 8765

# ALB health check hits / and /api/whisper/health (per AlbBackendStack rule).
HEALTHCHECK --interval=15s --timeout=5s --start-period=120s --retries=10 \
    CMD curl -fsS http://127.0.0.1:8765/health || exit 1

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8765", "--workers", "1"]
