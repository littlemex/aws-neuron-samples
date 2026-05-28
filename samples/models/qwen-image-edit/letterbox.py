"""Letterbox padding helper for Qwen-Image-Edit.

The compiled Neuron pipeline only accepts 1024x1024 RGB inputs (fixed shape
required by the traced graphs). When the user uploads a non-square image, a
naive resize to 1024x1024 stretches the content and the editor produces a
visibly distorted output (the bug).

This helper performs aspect-preserving "letterbox" padding:
  1. Scale the long edge to `target` (default 1024).
  2. Pad the short edge with black bars centered to reach `target` x `target`.
  3. Run inference at the fixed `target` x `target`.
  4. Crop the output back to the padded box and resize to the original (input)
     dimensions so the caller gets an image with the same aspect as the upload.

Usage in serve.py (replacing the `img.resize((W, H))` line):

    from letterbox import letterbox_pad, unletterbox

    pil_in = Image.open(io.BytesIO(data)).convert("RGB")
    orig_w, orig_h = pil_in.size
    padded, box = letterbox_pad(pil_in, target=SERVER_ARGS.width)
    # ... feed `padded` into the pipeline (height=W, width=W) ...
    out_img = pipe(...).images[0]
    final = unletterbox(out_img, box, (orig_w, orig_h))
    final.save(out_path)
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Tuple

from PIL import Image


@dataclass(frozen=True)
class LetterboxBox:
    """Position of the original (scaled) content within the padded canvas."""
    x: int
    y: int
    w: int
    h: int
    target: int


def letterbox_pad(img: Image.Image, target: int = 1024,
                  fill: Tuple[int, int, int] = (0, 0, 0)) -> Tuple[Image.Image, LetterboxBox]:
    """Pad `img` to a `target` x `target` square, preserving aspect ratio.

    Returns the padded image plus a `LetterboxBox` describing where the actual
    content lives inside the canvas — needed to crop the model output back to
    the input aspect ratio.
    """
    src_w, src_h = img.size
    if src_w <= 0 or src_h <= 0:
        raise ValueError(f"invalid image size: {src_w}x{src_h}")

    scale = min(target / src_w, target / src_h)
    new_w = max(1, int(round(src_w * scale)))
    new_h = max(1, int(round(src_h * scale)))
    new_w = min(new_w, target)
    new_h = min(new_h, target)

    resized = img.resize((new_w, new_h), Image.LANCZOS)
    canvas = Image.new("RGB", (target, target), fill)
    x = (target - new_w) // 2
    y = (target - new_h) // 2
    canvas.paste(resized, (x, y))
    return canvas, LetterboxBox(x=x, y=y, w=new_w, h=new_h, target=target)


def unletterbox(out: Image.Image, box: LetterboxBox,
                orig_size: Tuple[int, int]) -> Image.Image:
    """Reverse the letterbox: crop the content area and resize to `orig_size`.

    The model output may not be exactly `box.target` x `box.target` if the
    pipeline returned a different size (it shouldn't, but be defensive). We
    rescale the box coordinates proportionally before cropping.
    """
    out_w, out_h = out.size
    if out_w == box.target and out_h == box.target:
        crop_box = (box.x, box.y, box.x + box.w, box.y + box.h)
    else:
        sx = out_w / box.target
        sy = out_h / box.target
        crop_box = (
            int(round(box.x * sx)),
            int(round(box.y * sy)),
            int(round((box.x + box.w) * sx)),
            int(round((box.y + box.h) * sy)),
        )
    cropped = out.crop(crop_box)
    if cropped.size != orig_size:
        cropped = cropped.resize(orig_size, Image.LANCZOS)
    return cropped


if __name__ == "__main__":
    # quick self-test
    src = Image.new("RGB", (1280, 720), (255, 0, 0))
    padded, box = letterbox_pad(src, target=1024)
    assert padded.size == (1024, 1024), padded.size
    assert box.w == 1024, box
    assert box.h == 576, box  # 720 * (1024/1280) = 576
    assert box.x == 0 and box.y == (1024 - 576) // 2
    restored = unletterbox(padded, box, (1280, 720))
    assert restored.size == (1280, 720), restored.size
    print("[letterbox] self-test OK")
