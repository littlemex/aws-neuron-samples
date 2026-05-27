"""言語コードの正規化。

ASR backend ごとに期待するフォーマットが異なるため、共通の入口で吸収する。

  - Bedrock Transcribe Streaming: BCP-47 ("ja-JP", "en-US", "fr-FR", ...)
  - Whisper (Trainium 自前 server): 英語の言語名 ("japanese", "english", ...)

UI からは BCP-47 を渡す前提なので、Whisper 系では `whisper_language` で
言語名に変換する。未知のコードはそのまま返して、Whisper サーバ側に
判断を任せる (上流で 500 が返れば EngineError("provider_error") になる)。
"""
from __future__ import annotations

# BCP-47 → Whisper の英語名マッピング。Whisper の tokenizer LANGUAGES と一致させる。
_BCP47_TO_WHISPER: dict[str, str] = {
    "ja": "japanese",
    "en": "english",
    "zh": "chinese",
    "de": "german",
    "es": "spanish",
    "ru": "russian",
    "ko": "korean",
    "fr": "french",
    "pt": "portuguese",
    "tr": "turkish",
    "pl": "polish",
    "ca": "catalan",
    "nl": "dutch",
    "ar": "arabic",
    "sv": "swedish",
    "it": "italian",
    "id": "indonesian",
    "hi": "hindi",
    "fi": "finnish",
    "vi": "vietnamese",
    "he": "hebrew",
    "uk": "ukrainian",
    "el": "greek",
    "ms": "malay",
    "cs": "czech",
    "ro": "romanian",
    "da": "danish",
    "hu": "hungarian",
    "ta": "tamil",
    "no": "norwegian",
    "th": "thai",
    "ur": "urdu",
    "hr": "croatian",
    "bg": "bulgarian",
    "lt": "lithuanian",
    "la": "latin",
    "mi": "maori",
    "ml": "malayalam",
}


def whisper_language(code: str | None) -> str | None:
    """BCP-47 (例: ``ja-JP``) を Whisper が期待する英語名 (例: ``japanese``) に変換する。

    - ``None`` / 空文字 → ``None`` (auto detect 任せ)
    - ``ja-JP`` / ``JA-jp`` / ``ja`` → ``"japanese"``
    - 既に ``"japanese"`` のような英語名 → そのまま小文字化
    - 未知のコード → 入力を小文字化して返す (server 側で 4xx を返してもらう)
    """
    if not code:
        return None
    norm = code.strip().lower()
    if not norm:
        return None
    primary = norm.split("-", 1)[0]
    if primary in _BCP47_TO_WHISPER:
        return _BCP47_TO_WHISPER[primary]
    if norm in _BCP47_TO_WHISPER.values():
        return norm
    return norm
