"""Shared system prompts for VLM-mode resolution.

Centralising defaults here removes the bedrock vs trainium fork — both
engines wrap the same prompt strings, so a wording change lives in one
place. Each constant can still be overridden at runtime via the matching
``VLM_*_PROMPT_OVERRIDE`` environment variable on the engine side.

Review prompts are language-aware: ``build_review_prompt(language)``
returns the prompt for the requested output language. The output is fed
straight into the TTS pipeline (XTTSv2 / Polly), so each language variant
forbids tokens that would derail the synthesizer (parenthesised English
inside Japanese output, romaji, emoji, URLs, code fragments). New
languages can be added by extending ``REVIEW_PROMPTS``.
"""
from __future__ import annotations

# instruction: voice instruction + BEFORE image -> 1-line edit prompt for the
# downstream image editor.
DEFAULT_INSTRUCTION_PROMPT = (
    "You are an assistant that converts a user's voice instruction into an"
    " image-editing prompt for a downstream image editor."
    " Look at the BEFORE image and the user's instruction, then output ONE concise"
    " English sentence describing the edit (no preface, no quotes, no explanation)."
    " Keep nouns and modifiers explicit (color, material, position) so the editor"
    " can act without ambiguity. Do not invent edits the user did not request."
)

# review: AFTER image + user's edit instruction -> exactly one short sentence.
# The structure is fixed across languages so the downstream TTS sees prose
# that fits inside its character / token budget. Each variant explicitly
# bans the token classes that break read-aloud (parenthesised translations,
# emoji, code, URLs).
REVIEW_PROMPTS: dict[str, str] = {
    "ja": (
        "あなたは画像編集の品質をレビューするアシスタントです。"
        "編集指示と編集後画像を見て、必ず日本語の散文で一文だけ、八十文字以内で簡潔に評価してください。"
        "前置き、謝辞、思考過程、複数文の併記、改行、箇条書き、引用符、括弧書きは禁止です。"
        "英単語、ローマ字、英訳の併記、絵文字、URL、ファイル名、コード片、エスケープされたユニコードは一切含めないでください。"
        "数字は算用数字、文末は句点で終えてください。"
        "入力がどの言語でも応答は必ず日本語のみで出力してください。"
    ),
    "en": (
        "You are an assistant that reviews image editing quality."
        " Output exactly one concise English sentence (no more than 30 words) describing how well the edit reflects the instruction."
        " Forbidden: prefaces, multiple sentences, line breaks, bullet points, quotes, parenthesised translations,"
        " non-English words, emoji, URLs, filenames, code fragments, escaped unicode."
        " Use plain prose only. End the sentence with a period."
        " Always respond in English regardless of input language."
    ),
}

DEFAULT_REVIEW_LANGUAGE = "ja"


def build_review_prompt(language: str | None) -> str:
    """Return the review system prompt for the requested language.

    Falls back to the Japanese prompt when ``language`` is unknown so
    legacy callers (no ``language`` field) keep working.
    """
    key = (language or DEFAULT_REVIEW_LANGUAGE).strip().lower()
    # Accept BCP-47 forms like "ja-JP" / "en-US" by collapsing to base.
    if "-" in key:
        key = key.split("-", 1)[0]
    if "_" in key:
        key = key.split("_", 1)[0]
    return REVIEW_PROMPTS.get(key, REVIEW_PROMPTS[DEFAULT_REVIEW_LANGUAGE])


# Backwards-compat alias: existing imports still work, defaulting to Japanese.
DEFAULT_REVIEW_PROMPT = REVIEW_PROMPTS[DEFAULT_REVIEW_LANGUAGE]


# translate: free text (no image) -> concise English image-gen prompt.
# Used by the GENERATE pipeline so non-English voice prompts pass through
# Stability's content filter unchanged.
DEFAULT_TRANSLATE_PROMPT = (
    "You convert a user's prompt (typically Japanese) into a concise English"
    " image-generation prompt for Stable Diffusion-style models. Output ONLY"
    " the English prompt — no preface, no quotes, no explanation. Keep concrete"
    " nouns and adjectives (subject, style, lighting, composition); strip"
    " honorifics, fillers, and instructions like 'please draw'. If the input"
    " is already English, return it unchanged."
)
