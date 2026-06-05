"""Dummy engine: a stand-in that lets us exercise the UI / E2E pipeline
without hitting Bedrock.

Returns a flat-coloured PNG with the prompt rendered into it, throttled
to ~1.2s so the loading spinner behaves the same as a real provider.
"""
from __future__ import annotations

import base64
import io
import time

from PIL import Image, ImageDraw, ImageFont

from contracts import GenerateRequest, GenerateResponse
from engines._common import build_metadata
from engines.generate.base import ImageGenerateEngine


class DummyGenerateEngine(ImageGenerateEngine):
    name = "dummy"
    model_id = "dummy/text-to-banner-v1"

    def __init__(self, simulate_latency_ms: int = 1200) -> None:
        self.simulate_latency_ms = simulate_latency_ms

    def invoke(self, req: GenerateRequest) -> GenerateResponse:
        start = time.monotonic()
        # 1024x1024 dark teal canvas with the prompt rendered in the
        # centre. No external image dependency, no GPU.
        w, h = 1024, 1024
        img = Image.new("RGB", (w, h), color=(20, 40, 50))
        draw = ImageDraw.Draw(img)
        try:
            font = ImageFont.load_default(size=28)
        except TypeError:
            font = ImageFont.load_default()
        wrapped = req.prompt[:240]
        bbox = draw.textbbox((0, 0), wrapped, font=font)
        tw = bbox[2] - bbox[0]
        th = bbox[3] - bbox[1]
        draw.text(
            ((w - tw) / 2, (h - th) / 2),
            wrapped,
            fill=(220, 220, 220),
            font=font,
        )
        # Sleep to mimic provider latency so UI loaders behave the same.
        elapsed_ms = int((time.monotonic() - start) * 1000)
        if elapsed_ms < self.simulate_latency_ms:
            time.sleep((self.simulate_latency_ms - elapsed_ms) / 1000.0)

        buf = io.BytesIO()
        img.save(buf, format="PNG")
        return GenerateResponse(
            engine=self.name,
            image_b64=base64.b64encode(buf.getvalue()).decode("ascii"),
            metadata=build_metadata(
                model_id=self.model_id,
                start_monotonic=start,
                request_id=req.request_id,
                extra={"size": [w, h]},
            ),
        )
