"""Shared system prompts for VLM-mode resolution.

Centralising defaults here removes the bedrock vs trainium fork — both
engines wrap the same prompt strings, so a wording change lives in one
place. Each constant can still be overridden at runtime via the matching
``VLM_*_PROMPT_OVERRIDE`` environment variable on the engine side.
"""
from __future__ import annotations

# instruction: voice instruction (TEXT ONLY, no image) -> 1-line English edit
# prompt for the downstream image editor. This is a language transform, not an
# image-grounded task, so the BEFORE image is intentionally NOT provided (see
# the engine mode->content mapping). Keeping it text-only also avoids crashing
# the Neuron VLM on large images (image patches > vision bucket -> EngineCore
# AssertionError). review is the only mode that still receives an image.
DEFAULT_INSTRUCTION_PROMPT = (
    "You are an assistant that converts a user's (typically Japanese) voice"
    " instruction into an image-editing prompt for a downstream image editor."
    " Output ONE concise English sentence describing the requested edit"
    " (no preface, no quotes, no explanation)."
    " Keep nouns and modifiers explicit (color, material, position) so the editor"
    " can act without ambiguity. Do not invent edits the user did not request."
)

# review: AFTER image + user's edit instruction -> short review comment.
# Hard requirement (per product spec): the response MUST be written in
# Japanese, regardless of the input language. The model is also instructed
# to keep the response to three lines and to skip pleasantries / preambles.
# The output is fed straight into the TTS pipeline (XTTSv2 / Polly), so any
# English token, romaji, parenthesised English, code points or emoji breaks
# the synthesizer. The prompt therefore forbids every non-Japanese token
# explicitly and asks for plain prose only.
DEFAULT_REVIEW_PROMPT = (
    "あなたは画像編集の品質をレビューするアシスタントです。"
    "編集指示と編集後画像を見て、必ず日本語のみで簡潔な散文として三行以内でまとめてください。"
    "一行目は指示の反映度合い、二行目は違和感や破綻の有無、三行目は改善案を述べてください。"
    "応答は読み上げに使われるため、絶対に守るべきルールがあります。"
    "英単語、英文字、ローマ字、英訳の併記、括弧書き、箇条書きの記号、絵文字、URL、ファイル名、コード片を一切含めないでください。"
    "数字も日本語の数詞ではなく算用数字をそのまま使い、不要な記号は付けないでください。"
    "前置きや謝辞、ですます調以外の文体への切替は不要です。"
    "入力がどの言語であっても応答は必ず日本語のみで出力してください。"
)

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
