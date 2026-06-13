"""VLM 応答テキストの整形。

Qwen3-VL-Thinking 等が返す Chain-of-Thought (CoT) を取り除く。Neuron 版
vLLM では ``--reasoning-parser qwen3`` も ``chat_template_kwargs.
enable_thinking=False`` も実質的には効かず、思考が ``<think>...</think>``
タグなしで content に流れ込むケースが頻繁に観測された。そこでこのモジュ
ールは三段階の防御を実装する。

第一段階: 標準の ``<think>...</think>`` ブロック / dangling close /
trailing open の構造的除去。これは reasoning_parser が動いている環境
や、たまにタグを吐くモデルに有効。

第二段階: 出力言語フィルタ。応答の最終出力言語を caller が指定し、
段落単位で「目的言語の文字を含むかどうか」で残す。Qwen3-VL の
thinking は英語または中国語簡体で生成されるため、日本語応答を要求
した場合は ``ひらがな / カタカナ`` を含む段落だけを残せば reasoning
を高精度で除去できる。English 応答時は ASCII 主体の段落だけを残し、
CJK が混じる thinking 段落を捨てる。

第三段階: フィルタ後に何も残らないケース (thinking が長すぎて本文に
到達しなかった) は空文字を返し、上位層が EngineError として扱える
ようにする。
"""
from __future__ import annotations

import re

_THINK_BLOCK_RE = re.compile(r"<think\b[^>]*>.*?</think>", re.DOTALL | re.IGNORECASE)
_TRAILING_THINK_OPEN_RE = re.compile(r"<think\b[^>]*>.*$", re.DOTALL | re.IGNORECASE)
_DANGLING_THINK_CLOSE_RE = re.compile(r"^.*?</think\s*>", re.DOTALL | re.IGNORECASE)

# Hiragana + Katakana ranges. Picking either guarantees Japanese (Chinese
# never uses these blocks) so it works as a precise discriminator against
# the simplified-Chinese reasoning Qwen3 sometimes emits.
_JA_KANA_RE = re.compile(r"[぀-ゟ゠-ヿ]")
# CJK ideographs cover both Japanese kanji and Chinese hanzi; we use this
# only as a tiebreaker, never alone.
_CJK_IDEOGRAPH_RE = re.compile(r"[一-鿿]")
# A simple ASCII-letter test for English mode.
_ASCII_LETTER_RE = re.compile(r"[A-Za-z]")
# Paragraph boundary: blank lines or a single newline. We split on single
# newlines first because Qwen3 thinking tends to use \n\n between
# reasoning chunks but single \n between continuation phrases.
_PARAGRAPH_SPLIT_RE = re.compile(r"\n+")


def _is_japanese_paragraph(p: str) -> bool:
    """Treat a paragraph as Japanese only if it contains kana.

    Kana presence is the only reliable discriminator against Chinese,
    which Qwen3 thinking favours. Pure-kanji "Japanese" sentences without
    kana are rare in natural Japanese prose (and most that do occur are
    actually Chinese reasoning), so requiring at least one kana glyph
    avoids accidentally keeping Chinese paragraphs.
    """
    return bool(_JA_KANA_RE.search(p))


def _is_english_paragraph(p: str) -> bool:
    """English paragraphs contain ASCII letters and no CJK ideographs."""
    if _CJK_IDEOGRAPH_RE.search(p) or _JA_KANA_RE.search(p):
        return False
    return bool(_ASCII_LETTER_RE.search(p))


def _filter_paragraphs_by_language(text: str, language: str) -> str:
    """Return only the paragraphs whose primary language matches.

    For ``ja`` we keep paragraphs that contain hiragana / katakana (or
    pure-kanji Japanese) and drop everything else (English / Chinese
    reasoning). For ``en`` we keep ASCII-letter paragraphs and drop CJK.
    Unknown languages: pass-through.
    """
    if not text:
        return text
    paragraphs = [p.strip() for p in _PARAGRAPH_SPLIT_RE.split(text) if p and p.strip()]
    if not paragraphs:
        return text.strip()

    lang = (language or "").strip().lower().split("-", 1)[0].split("_", 1)[0]
    if lang == "ja":
        kept = [p for p in paragraphs if _is_japanese_paragraph(p)]
    elif lang == "en":
        kept = [p for p in paragraphs if _is_english_paragraph(p)]
    else:
        kept = paragraphs
    return "\n".join(kept).strip()


def strip_thinking(text: str, language: str | None = None) -> tuple[str, bool]:
    """Strip CoT thinking blocks from ``text``.

    Three layers run in order:
      1. Remove paired ``<think>...</think>`` blocks plus dangling
         opens / closes. Works when the model emits structural tags.
      2. When ``language`` is given, drop any paragraph whose primary
         language differs from the requested output language. This is
         what catches Qwen3 emitting English / Chinese reasoning
         without tags.
      3. Trim whitespace.

    Returns ``(cleaned, was_stripped)`` so callers can log the change.
    """
    if not text:
        return text, False
    original = text
    cleaned = _THINK_BLOCK_RE.sub("", text)
    if "</think>" in cleaned.lower() and "<think" not in cleaned.lower():
        cleaned = _DANGLING_THINK_CLOSE_RE.sub("", cleaned, count=1)
    elif "<think" in cleaned.lower() and "</think>" not in cleaned.lower():
        cleaned = _TRAILING_THINK_OPEN_RE.sub("", cleaned)

    if language:
        cleaned = _filter_paragraphs_by_language(cleaned, language)

    cleaned_stripped = cleaned.strip()
    return cleaned_stripped, cleaned_stripped != original.strip()
