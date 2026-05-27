"""VLM 応答テキスト整形。

Qwen3-VL-Thinking 等が返す ``<think>...</think>`` Chain-of-Thought (CoT) ブロックを
除去する。Bedrock 系は thinking を露出しない (Converse API が組み立てたメッセージから
text のみ拾う) ので、Trainium 側だけで使う。

ケース:
  - "...<think>X</think> Final"            → "Final"
  - "preface </think> Final"               → "Final"  (open タグ欠損: dangling close)
  - "<think>X" (close 欠損 / 切断)         → ""       (本文が無い)
  - "Plain answer"                         → そのまま
  - 複数ブロック / 大文字小文字混在も対応。
"""
from __future__ import annotations

import re

_THINK_BLOCK_RE = re.compile(r"<think\b[^>]*>.*?</think>", re.DOTALL | re.IGNORECASE)
_TRAILING_THINK_OPEN_RE = re.compile(r"<think\b[^>]*>.*$", re.DOTALL | re.IGNORECASE)
_DANGLING_THINK_CLOSE_RE = re.compile(r"^.*?</think\s*>", re.DOTALL | re.IGNORECASE)


def strip_thinking(text: str) -> tuple[str, bool]:
    """``text`` から CoT thinking ブロックを除去する。

    返り値: ``(cleaned, was_stripped)``
      - ``was_stripped=True`` → タグを除去した
      - ``was_stripped=False`` → 元と同じ (空白 trim だけは差分扱いしない)
    """
    if not text:
        return text, False
    original = text
    cleaned = _THINK_BLOCK_RE.sub("", text)
    if "</think>" in cleaned.lower() and "<think" not in cleaned.lower():
        cleaned = _DANGLING_THINK_CLOSE_RE.sub("", cleaned, count=1)
    elif "<think" in cleaned.lower() and "</think>" not in cleaned.lower():
        cleaned = _TRAILING_THINK_OPEN_RE.sub("", cleaned)
    cleaned_stripped = cleaned.strip()
    return cleaned_stripped, cleaned_stripped != original.strip()
