"""engines/_common/ ヘルパー単体テスト。

3 スロットの実装が依存する共通ロジックなので、ここを通せば後続実装の
構造的振る舞い (env, decode, http_status, metadata, thinking strip) が
揃って担保される。
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from contracts import EngineError  # noqa: E402
from engines._common import (  # noqa: E402
    build_metadata,
    decode_audio_b64,
    decode_image_b64,
    env_float,
    env_int,
    env_required,
    guess_image_format,
    guess_image_mime,
    raise_for_status,
    strip_thinking,
    whisper_language,
)


# ---------------------------------------------------------------------------
# env helpers
# ---------------------------------------------------------------------------


class TestEnvRequired:
    def test_returns_first_set(self, monkeypatch):
        monkeypatch.setenv("FOO_A", "a")
        monkeypatch.setenv("FOO_B", "b")
        assert env_required("FOO_A", "FOO_B") == "a"

    def test_falls_back(self, monkeypatch):
        monkeypatch.delenv("FOO_A", raising=False)
        monkeypatch.setenv("FOO_B", "b")
        assert env_required("FOO_A", "FOO_B") == "b"

    def test_raises_config_missing(self, monkeypatch):
        monkeypatch.delenv("FOO_A", raising=False)
        monkeypatch.delenv("FOO_B", raising=False)
        with pytest.raises(EngineError) as exc:
            env_required("FOO_A", "FOO_B")
        assert exc.value.code == "config_missing"
        assert "FOO_A" in exc.value.message and "FOO_B" in exc.value.message


class TestEnvFloat:
    def test_default(self, monkeypatch):
        monkeypatch.delenv("X", raising=False)
        assert env_float("X", 1.5) == 1.5

    def test_int_literal(self, monkeypatch):
        monkeypatch.setenv("X", "60")
        assert env_float("X", 1.0) == 60.0

    def test_invalid_raises(self, monkeypatch):
        monkeypatch.setenv("X", "abc")
        with pytest.raises(EngineError) as exc:
            env_float("X", 1.0)
        assert exc.value.code == "config_missing"

    def test_fallback(self, monkeypatch):
        monkeypatch.delenv("X", raising=False)
        monkeypatch.setenv("Y", "42")
        assert env_float("X", 1.0, fallback=("Y",)) == 42.0


class TestEnvInt:
    def test_default(self, monkeypatch):
        monkeypatch.delenv("X", raising=False)
        assert env_int("X", 7) == 7

    def test_invalid_raises(self, monkeypatch):
        monkeypatch.setenv("X", "1.5")
        with pytest.raises(EngineError) as exc:
            env_int("X", 1)
        assert exc.value.code == "config_missing"


# ---------------------------------------------------------------------------
# decode helpers
# ---------------------------------------------------------------------------


class TestDecodeImage:
    def test_invalid_b64(self):
        with pytest.raises(EngineError) as exc:
            decode_image_b64("!!!")
        assert exc.value.code == "invalid_request"

    def test_empty(self):
        with pytest.raises(EngineError) as exc:
            decode_image_b64("")
        assert exc.value.code == "invalid_request"

    def test_round_trip(self):
        import base64

        b = b"\x89PNG\r\n\x1a\nrest"
        assert decode_image_b64(base64.b64encode(b).decode("ascii")) == b


class TestDecodeAudio:
    def test_invalid_b64(self):
        with pytest.raises(EngineError) as exc:
            decode_audio_b64("!!!")
        assert exc.value.code == "invalid_request"

    def test_empty_default_rejects(self):
        with pytest.raises(EngineError) as exc:
            decode_audio_b64("")
        assert exc.value.code == "invalid_request"

    def test_empty_allowed(self):
        # Trainium ASR は空 audio も client から来る場合があるため、許容する
        # オプションを提供する (テストでも使われている挙動)
        assert decode_audio_b64("", allow_empty=True) == b""


class TestGuessImageMime:
    def test_png(self):
        assert guess_image_mime(b"\x89PNG\r\n\x1a\n...") == "image/png"

    def test_jpeg(self):
        assert guess_image_mime(b"\xff\xd8\xff\xe0...") == "image/jpeg"

    def test_gif(self):
        assert guess_image_mime(b"GIF89a...") == "image/gif"

    def test_webp(self):
        assert guess_image_mime(b"RIFF\x00\x00\x00\x00WEBPxxx") == "image/webp"

    def test_unknown_falls_back_to_png(self):
        assert guess_image_mime(b"\x00\x01\x02\x03") == "image/png"


def test_guess_image_format_strips_image_prefix():
    assert guess_image_format(b"\x89PNG\r\n\x1a\n...") == "png"


# ---------------------------------------------------------------------------
# http
# ---------------------------------------------------------------------------


class _FakeResp:
    def __init__(self, status: int, body: bytes = b""):
        self.status = status
        self.data = body


class TestRaiseForStatus:
    def test_5xx_is_retryable_provider_error(self):
        with pytest.raises(EngineError) as exc:
            raise_for_status(_FakeResp(503, b"upstream"), label="x")
        assert exc.value.code == "provider_error"
        assert exc.value.retryable is True

    def test_4xx_default_invalid_response(self):
        with pytest.raises(EngineError) as exc:
            raise_for_status(_FakeResp(400, b"bad"), label="x")
        assert exc.value.code == "provider_invalid_response"
        assert exc.value.retryable is False

    def test_4xx_can_be_provider_error(self):
        # EDIT engine は 4xx を provider_error として扱う後方互換が必要
        with pytest.raises(EngineError) as exc:
            raise_for_status(
                _FakeResp(404, b"nf"), label="x", four_xx_code="provider_error"
            )
        assert exc.value.code == "provider_error"
        assert exc.value.retryable is False

    def test_2xx_does_nothing(self):
        raise_for_status(_FakeResp(200, b"ok"), label="x")
        raise_for_status(_FakeResp(204, b""), label="x")


# ---------------------------------------------------------------------------
# metadata
# ---------------------------------------------------------------------------


class TestBuildMetadata:
    def test_latency_ms(self):
        start = time.monotonic() - 0.05  # 50ms 前
        meta = build_metadata(
            model_id="m", start_monotonic=start, request_id="rid", extra={"k": 1}
        )
        assert meta.model_id == "m"
        assert meta.request_id == "rid"
        assert meta.extra == {"k": 1}
        assert 40 <= meta.latency_ms <= 200  # 余裕を持って

    def test_request_id_default_uuid(self):
        meta = build_metadata(
            model_id="m", start_monotonic=time.monotonic(), request_id=None
        )
        # uuid4 string は 36 文字 (8-4-4-4-12)
        assert isinstance(meta.request_id, str) and len(meta.request_id) == 36


# ---------------------------------------------------------------------------
# strip_thinking
# ---------------------------------------------------------------------------


class TestStripThinking:
    def test_plain(self):
        assert strip_thinking("Hello world") == ("Hello world", False)

    def test_paired_block(self):
        assert strip_thinking("<think>internal</think> Final answer") == (
            "Final answer",
            True,
        )

    def test_qwen_dangling_close(self):
        text = (
            "Got it, let's see... </think> Change the blue in the right half to green"
        )
        out, was = strip_thinking(text)
        assert was is True
        assert out == "Change the blue in the right half to green"

    def test_open_without_close(self):
        out, was = strip_thinking("<think>X internal not closed")
        assert was is True
        assert out == ""

    def test_multiple_blocks(self):
        out, was = strip_thinking("<think>a</think>middle<think>b</think>end")
        assert was is True
        assert out == "middleend"

    def test_mixed_case(self):
        out, was = strip_thinking("<THINK>x</THINK> final")
        assert was is True
        assert out == "final"

    def test_empty_input(self):
        assert strip_thinking("") == ("", False)

    def test_whitespace_alone_not_counted(self):
        # Trim だけは was_stripped=False (タグが除去されたわけではない)
        assert strip_thinking("  hi  ") == ("hi", False)


# ---------------------------------------------------------------------------
# whisper_language
# ---------------------------------------------------------------------------


class TestWhisperLanguage:
    def test_none_passes_through(self):
        assert whisper_language(None) is None
        assert whisper_language("") is None
        assert whisper_language("   ") is None

    def test_bcp47_japanese(self):
        assert whisper_language("ja-JP") == "japanese"
        assert whisper_language("JA-jp") == "japanese"
        assert whisper_language("ja") == "japanese"

    def test_bcp47_english(self):
        assert whisper_language("en-US") == "english"
        assert whisper_language("en") == "english"

    def test_already_whisper_name(self):
        # Whisper ネイティブ名はそのまま小文字化して通す
        assert whisper_language("japanese") == "japanese"
        assert whisper_language("ENGLISH") == "english"

    def test_unknown_passes_lowercase(self):
        # 知らないコードは server に判断を任せるため lower で通す
        assert whisper_language("xx-XX") == "xx-xx"
