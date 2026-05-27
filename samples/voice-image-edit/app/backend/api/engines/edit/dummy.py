"""Dummy エンジン: trn / Bedrock を使わずに UI E2E を回すための疑似エンジン。

入力画像にプロンプトを白帯で焼き込んで返す。レイテンシは 1.5s 程度に揃え、
本番系と同じ感覚で UI 開発できるようにする。
"""
from __future__ import annotations

import base64
import io
import time

from PIL import Image, ImageDraw, ImageFont

from contracts import EditRequest, EditResponse, EngineError
from engines.edit.base import ImageEditEngine
from engines._common import build_metadata


class DummyEditEngine(ImageEditEngine):
    name = "dummy"
    model_id = "dummy/banner-overlay-v1"

    def __init__(self, simulate_latency_ms: int = 1500) -> None:
        self.simulate_latency_ms = simulate_latency_ms

    def invoke(self, req: EditRequest) -> EditResponse:
        start = time.monotonic()
        try:
            raw = base64.b64decode(req.image_b64, validate=True)
            img = Image.open(io.BytesIO(raw)).convert("RGB")
        except Exception as exc:
            raise EngineError("invalid_image", f"failed to decode image: {exc}") from exc

        edited = self._render_banner(img, req.prompt)
        out = io.BytesIO()
        edited.save(out, format="PNG")
        out_b64 = base64.b64encode(out.getvalue()).decode("ascii")

        elapsed = int((time.monotonic() - start) * 1000)
        sleep_ms = max(0, self.simulate_latency_ms - elapsed)
        time.sleep(sleep_ms / 1000.0)

        return EditResponse(
            engine=self.name,
            image_b64=out_b64,
            metadata=build_metadata(
                model_id=self.model_id,
                start_monotonic=start,
                request_id=req.request_id,
                extra={"simulated_latency_ms": self.simulate_latency_ms},
            ),
        )

    def _render_banner(self, img: Image.Image, prompt: str) -> Image.Image:
        canvas = img.copy()
        w, h = canvas.size
        band_h = max(40, h // 12)
        draw = ImageDraw.Draw(canvas)
        draw.rectangle([(0, 0), (w, band_h)], fill=(255, 255, 255))
        try:
            font = ImageFont.truetype(
                "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf",
                size=max(14, band_h // 2),
            )
        except OSError:
            font = ImageFont.load_default()
        text = f"[DUMMY] {prompt[:80]}"
        draw.text((10, band_h // 6), text, fill=(0, 0, 0), font=font)
        return canvas
