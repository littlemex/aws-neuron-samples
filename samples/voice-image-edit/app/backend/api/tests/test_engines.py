"""contracts と DummyEditEngine + 3 スロット registry の最小ユニットテスト。

bedrock_* / trainium 系は外部 SDK / HTTP に依存するため、ここでは構築時の
環境変数 guard のみテストする (実際の API 呼び出しは P2 / P3 で別途検証)。
"""
from __future__ import annotations

import base64
import io
import json
import sys
from pathlib import Path

import pytest
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from contracts import (  # noqa: E402
    AsrRequest,
    EditRequest,
    EngineError,
    VlmRequest,
)
import engines as registry  # noqa: E402
from engines.edit.dummy import DummyEditEngine  # noqa: E402


def _png_b64(size: tuple[int, int] = (320, 240)) -> str:
    img = Image.new("RGB", size, color=(120, 80, 40))
    buf = io.BytesIO()
    img.save(buf, format="PNG")
    return base64.b64encode(buf.getvalue()).decode("ascii")


# ---------------------------------------------------------------------------
# 契約 (Request 検証)
# ---------------------------------------------------------------------------


class TestEditRequest:
    def test_minimal(self):
        req = EditRequest.from_dict({"image_b64": "AAA", "prompt": "p"})
        assert req.image_b64 == "AAA"
        assert req.prompt == "p"
        assert req.engine is None
        assert req.options.strength == 0.7

    def test_missing_prompt_raises(self):
        with pytest.raises(EngineError) as exc:
            EditRequest.from_dict({"image_b64": "x"})
        assert exc.value.code == "invalid_request"

    def test_options_passthrough(self):
        req = EditRequest.from_dict(
            {
                "image_b64": "x",
                "prompt": "p",
                "engine": "dummy",
                "options": {"strength": 0.5, "seed": 42, "negative_prompt": "ng"},
            }
        )
        assert req.options.strength == 0.5
        assert req.options.seed == 42
        assert req.options.negative_prompt == "ng"


class TestAsrRequest:
    def test_minimal(self):
        req = AsrRequest.from_dict({"audio_b64": "AAA"})
        assert req.audio_b64 == "AAA"
        assert req.mime_type == "audio/webm"
        assert req.language is None

    def test_missing_audio_raises(self):
        with pytest.raises(EngineError) as exc:
            AsrRequest.from_dict({})
        assert exc.value.code == "invalid_request"


class TestVlmRequest:
    def test_minimal(self):
        req = VlmRequest.from_dict({"image_b64": "AAA", "prompt": "describe"})
        assert req.image_b64 == "AAA"
        assert req.prompt == "describe"
        assert req.mode == "instruction"

    def test_review_mode(self):
        req = VlmRequest.from_dict(
            {"image_b64": "AAA", "prompt": "rate it", "mode": "review"}
        )
        assert req.mode == "review"

    def test_unknown_mode_raises(self):
        with pytest.raises(EngineError) as exc:
            VlmRequest.from_dict(
                {"image_b64": "AAA", "prompt": "x", "mode": "wat"}
            )
        assert exc.value.code == "invalid_request"


# ---------------------------------------------------------------------------
# DummyEditEngine (実装が完結している唯一のエンジン)
# ---------------------------------------------------------------------------


class TestDummyEngine:
    def test_invoke_returns_png(self):
        engine = DummyEditEngine(simulate_latency_ms=0)
        req = EditRequest(image_b64=_png_b64(), prompt="赤いドレスに")
        out = engine.invoke(req)
        assert out.engine == "dummy"
        assert out.image_b64
        Image.open(io.BytesIO(base64.b64decode(out.image_b64))).verify()
        assert out.metadata.model_id.startswith("dummy/")
        assert out.metadata.latency_ms >= 0

    def test_invoke_invalid_image_raises(self):
        engine = DummyEditEngine(simulate_latency_ms=0)
        req = EditRequest(image_b64="!!!notbase64!!!", prompt="p")
        with pytest.raises(EngineError) as exc:
            engine.invoke(req)
        assert exc.value.code == "invalid_image"


# ---------------------------------------------------------------------------
# 3 スロット registry
# ---------------------------------------------------------------------------


class TestRegistry:
    def test_list_slots(self):
        assert registry.list_slots() == ["asr", "vlm", "edit"]

    def test_edit_engines_include_dummy_and_bedrock_and_trainium(self):
        names = registry.list_engines("edit")
        assert "dummy" in names
        assert "bedrock_nova_canvas" in names
        assert "trainium" in names

    def test_asr_engines_have_bedrock_and_trainium(self):
        names = registry.list_engines("asr")
        assert "bedrock_transcribe" in names
        assert "bedrock_nova_sonic" in names
        assert "trainium" in names

    def test_vlm_engines_have_multiple_bedrock(self):
        names = registry.list_engines("vlm")
        assert "bedrock_claude_sonnet" in names
        assert "bedrock_nova_pro" in names
        assert "bedrock_nova_lite" in names
        assert "trainium" in names

    def test_unknown_slot_raises(self):
        with pytest.raises(EngineError) as exc:
            registry.list_engines("xxx")
        assert exc.value.code == "unknown_slot"

    def test_unknown_edit_engine_raises(self):
        with pytest.raises(EngineError) as exc:
            registry.get_engine("edit", "does-not-exist")
        assert exc.value.code == "unknown_engine"

    def test_default_edit_falls_back_to_dummy(self, monkeypatch):
        monkeypatch.delenv("EDIT_ENGINE_DEFAULT", raising=False)
        engine = registry.get_engine("edit", None)
        assert engine.name == "dummy"


# ---------------------------------------------------------------------------
# 環境変数 guard (構築時に外部 API は叩かないこと)
# ---------------------------------------------------------------------------


class TestEnvGuards:
    def test_bedrock_edit_requires_env(self, monkeypatch):
        monkeypatch.delenv("BEDROCK_REGION", raising=False)
        monkeypatch.delenv("BEDROCK_EDIT_MODEL_ID", raising=False)
        monkeypatch.delenv("NOVA_CANVAS_MODEL_ID", raising=False)
        from engines.edit.bedrock import BedrockEditEngine

        with pytest.raises(EngineError) as exc:
            BedrockEditEngine()
        assert exc.value.code == "config_missing"

    def test_trainium_edit_requires_env(self, monkeypatch):
        monkeypatch.delenv("TRAINIUM_EDIT_URL", raising=False)
        monkeypatch.delenv("TRAINIUM_BACKEND_URL", raising=False)
        from engines.edit.trainium import TrainiumEditEngine

        with pytest.raises(EngineError) as exc:
            TrainiumEditEngine()
        assert exc.value.code == "config_missing"

    def test_bedrock_asr_requires_env(self, monkeypatch):
        monkeypatch.delenv("BEDROCK_REGION", raising=False)
        monkeypatch.delenv("AWS_REGION", raising=False)
        from engines.asr.bedrock import BedrockAsrEngine

        with pytest.raises(EngineError) as exc:
            BedrockAsrEngine()
        assert exc.value.code == "config_missing"

    def test_trainium_asr_requires_env(self, monkeypatch):
        monkeypatch.delenv("TRAINIUM_ASR_URL", raising=False)
        from engines.asr.trainium import TrainiumAsrEngine

        with pytest.raises(EngineError) as exc:
            TrainiumAsrEngine()
        assert exc.value.code == "config_missing"

    def test_bedrock_vlm_requires_env(self, monkeypatch):
        monkeypatch.delenv("BEDROCK_REGION", raising=False)
        monkeypatch.delenv("AWS_REGION", raising=False)
        monkeypatch.delenv("BEDROCK_VLM_MODEL_ID", raising=False)
        from engines.vlm.bedrock import BedrockVlmEngine

        with pytest.raises(EngineError) as exc:
            BedrockVlmEngine()
        assert exc.value.code == "config_missing"

    def test_trainium_vlm_requires_env(self, monkeypatch):
        monkeypatch.delenv("TRAINIUM_VLM_URL", raising=False)
        from engines.vlm.trainium import TrainiumVlmEngine

        with pytest.raises(EngineError) as exc:
            TrainiumVlmEngine()
        assert exc.value.code == "config_missing"


# ---------------------------------------------------------------------------
# Bedrock Transcribe (sync wrapper) — 音声フォーマット / SDK 不在時の挙動
# ---------------------------------------------------------------------------


class TestBedrockAsr:
    def test_rejects_non_pcm_mime(self, monkeypatch):
        monkeypatch.setenv("BEDROCK_REGION", "us-east-1")
        from engines.asr.bedrock import BedrockAsrEngine

        engine = BedrockAsrEngine(backend="transcribe")
        with pytest.raises(EngineError) as exc:
            engine.invoke(
                AsrRequest(audio_b64="AAAA", mime_type="audio/webm")
            )
        assert exc.value.code == "invalid_request"

    def test_rejects_invalid_base64(self, monkeypatch):
        monkeypatch.setenv("BEDROCK_REGION", "us-east-1")
        from engines.asr.bedrock import BedrockAsrEngine

        engine = BedrockAsrEngine(backend="transcribe")
        with pytest.raises(EngineError) as exc:
            engine.invoke(
                AsrRequest(
                    audio_b64="!!!not_b64!!!",
                    mime_type="audio/pcm; rate=16000",
                )
            )
        assert exc.value.code == "invalid_request"

    def test_rejects_empty_audio(self, monkeypatch):
        monkeypatch.setenv("BEDROCK_REGION", "us-east-1")
        from engines.asr.bedrock import BedrockAsrEngine

        engine = BedrockAsrEngine(backend="transcribe")
        with pytest.raises(EngineError) as exc:
            engine.invoke(
                AsrRequest(audio_b64="", mime_type="audio/pcm; rate=16000")
            )
        assert exc.value.code == "invalid_request"

    def test_nova_sonic_is_not_implemented(self, monkeypatch):
        monkeypatch.setenv("BEDROCK_REGION", "us-east-1")
        from engines.asr.bedrock import BedrockAsrEngine

        engine = BedrockAsrEngine(backend="nova_sonic")
        with pytest.raises(EngineError) as exc:
            engine.invoke(
                AsrRequest(audio_b64="AAAA", mime_type="audio/pcm; rate=16000")
            )
        assert exc.value.code == "not_implemented"


# ---------------------------------------------------------------------------
# Trainium ASR — HTTP プロキシのリクエスト整形と応答 parse
# ---------------------------------------------------------------------------


class _FakeResp:
    def __init__(self, status: int, body: bytes):
        self.status = status
        self.data = body


class _FakeHttp:
    def __init__(self, resp: _FakeResp):
        self._resp = resp
        self.captured: dict | None = None

    def request(self, method, url, body=None, headers=None, timeout=None, retries=None):
        self.captured = {
            "method": method,
            "url": url,
            "body": body,
            "headers": headers or {},
        }
        return self._resp


class TestTrainiumAsr:
    def test_success_returns_text_and_segments(self, monkeypatch):
        monkeypatch.setenv("TRAINIUM_ASR_URL", "http://example.invalid/transcribe")
        from engines.asr.trainium import TrainiumAsrEngine

        engine = TrainiumAsrEngine()
        engine._http = _FakeHttp(
            _FakeResp(
                200,
                b'{"text":"hello","segments":[{"start_ms":0,"end_ms":500,"text":"hello"}]}',
            )
        )
        audio = base64.b64encode(b"\x00\x01" * 8000).decode("ascii")
        out = engine.invoke(
            AsrRequest(
                audio_b64=audio,
                mime_type="audio/pcm; rate=16000",
                language="ja",
            )
        )
        assert out.text == "hello"
        assert len(out.segments) == 1
        assert engine._http.captured["headers"]["X-Sample-Rate"] == "16000"
        assert engine._http.captured["headers"]["X-Language"] == "ja"
        assert engine._http.captured["body"] == b"\x00\x01" * 8000

    def test_5xx_is_retryable_provider_error(self, monkeypatch):
        monkeypatch.setenv("TRAINIUM_ASR_URL", "http://example.invalid/transcribe")
        from engines.asr.trainium import TrainiumAsrEngine

        engine = TrainiumAsrEngine()
        engine._http = _FakeHttp(_FakeResp(503, b"upstream down"))
        with pytest.raises(EngineError) as exc:
            engine.invoke(
                AsrRequest(audio_b64=base64.b64encode(b"\x00").decode("ascii"))
            )
        assert exc.value.code == "provider_error"
        assert exc.value.retryable is True

    def test_non_json_body_is_invalid_response(self, monkeypatch):
        monkeypatch.setenv("TRAINIUM_ASR_URL", "http://example.invalid/transcribe")
        from engines.asr.trainium import TrainiumAsrEngine

        engine = TrainiumAsrEngine()
        engine._http = _FakeHttp(_FakeResp(200, b"not json"))
        with pytest.raises(EngineError) as exc:
            engine.invoke(
                AsrRequest(audio_b64=base64.b64encode(b"\x00").decode("ascii"))
            )
        assert exc.value.code == "provider_invalid_response"

    def test_missing_text_field_is_invalid_response(self, monkeypatch):
        monkeypatch.setenv("TRAINIUM_ASR_URL", "http://example.invalid/transcribe")
        from engines.asr.trainium import TrainiumAsrEngine

        engine = TrainiumAsrEngine()
        engine._http = _FakeHttp(_FakeResp(200, b'{"oops":1}'))
        with pytest.raises(EngineError) as exc:
            engine.invoke(
                AsrRequest(audio_b64=base64.b64encode(b"\x00").decode("ascii"))
            )
        assert exc.value.code == "provider_invalid_response"


# ---------------------------------------------------------------------------
# Bedrock VLM — Converse API リクエスト整形 / 応答 parse
# ---------------------------------------------------------------------------


class _FakeBedrockClient:
    def __init__(self, response: dict | None = None, raise_exc: Exception | None = None):
        self._response = response or {}
        self._raise = raise_exc
        self.last_kwargs: dict | None = None

    def converse(self, **kwargs):
        self.last_kwargs = kwargs
        if self._raise:
            raise self._raise
        return self._response


def _make_bedrock_vlm(monkeypatch, client):
    monkeypatch.setenv("BEDROCK_REGION", "us-east-1")
    monkeypatch.setenv("BEDROCK_VLM_MODEL_ID", "anthropic.claude-3-5-sonnet-20241022-v2:0")
    from engines.vlm.bedrock import BedrockVlmEngine

    engine = BedrockVlmEngine()
    engine._client = client
    return engine


class TestBedrockVlm:
    def test_instruction_mode_returns_text(self, monkeypatch):
        client = _FakeBedrockClient(
            response={
                "output": {
                    "message": {
                        "role": "assistant",
                        "content": [{"text": "Replace the dress with red."}],
                    }
                },
                "stopReason": "end_turn",
                "usage": {"inputTokens": 10, "outputTokens": 7},
            }
        )
        engine = _make_bedrock_vlm(monkeypatch, client)
        out = engine.invoke(
            VlmRequest(image_b64=_png_b64(), prompt="赤いドレスに変更", mode="instruction")
        )
        assert out.text == "Replace the dress with red."
        assert client.last_kwargs is not None
        assert client.last_kwargs["modelId"].startswith("anthropic.claude")
        assert client.last_kwargs["system"][0]["text"]
        msg = client.last_kwargs["messages"][0]
        assert msg["role"] == "user"
        assert msg["content"][0]["image"]["format"] == "png"
        assert msg["content"][1]["text"] == "赤いドレスに変更"

    def test_review_mode_uses_review_prompt(self, monkeypatch):
        client = _FakeBedrockClient(
            response={
                "output": {
                    "message": {"content": [{"text": "ok"}]}
                }
            }
        )
        engine = _make_bedrock_vlm(monkeypatch, client)
        engine.invoke(
            VlmRequest(image_b64=_png_b64(), prompt="編集を確認して", mode="review")
        )
        sys_text = client.last_kwargs["system"][0]["text"]
        assert "レビュー" in sys_text

    def test_invalid_image_b64(self, monkeypatch):
        engine = _make_bedrock_vlm(monkeypatch, _FakeBedrockClient())
        with pytest.raises(EngineError) as exc:
            engine.invoke(VlmRequest(image_b64="!!!", prompt="x"))
        assert exc.value.code == "invalid_request"

    def test_empty_text_is_invalid_response(self, monkeypatch):
        client = _FakeBedrockClient(
            response={"output": {"message": {"content": []}}}
        )
        engine = _make_bedrock_vlm(monkeypatch, client)
        with pytest.raises(EngineError) as exc:
            engine.invoke(VlmRequest(image_b64=_png_b64(), prompt="x"))
        assert exc.value.code == "provider_invalid_response"


# ---------------------------------------------------------------------------
# Trainium VLM — OpenAI 互換プロキシ
# ---------------------------------------------------------------------------


class TestTrainiumVlm:
    def test_success_returns_text(self, monkeypatch):
        monkeypatch.setenv("TRAINIUM_VLM_URL", "http://example.invalid/v1/chat/completions")
        from engines.vlm.trainium import TrainiumVlmEngine

        engine = TrainiumVlmEngine()
        engine._http = _FakeHttp(
            _FakeResp(
                200,
                b'{"choices":[{"message":{"role":"assistant","content":"Make it red."}}],'
                b'"usage":{"prompt_tokens":3,"completion_tokens":4}}',
            )
        )
        out = engine.invoke(
            VlmRequest(
                image_b64=_png_b64(),
                prompt="赤くして",
                mode="instruction",
            )
        )
        assert out.text == "Make it red."
        sent = engine._http.captured
        body = json.loads(sent["body"].decode("utf-8"))
        assert body["model"] == engine.model_id
        assert body["messages"][0]["role"] == "system"
        assert body["messages"][1]["content"][0]["type"] == "image_url"
        assert body["messages"][1]["content"][0]["image_url"]["url"].startswith(
            "data:image/png;base64,"
        )

    def test_api_key_passed_as_bearer(self, monkeypatch):
        monkeypatch.setenv("TRAINIUM_VLM_URL", "http://example.invalid/v1/chat/completions")
        monkeypatch.setenv("TRAINIUM_VLM_API_KEY", "sekret")
        from engines.vlm.trainium import TrainiumVlmEngine

        engine = TrainiumVlmEngine()
        engine._http = _FakeHttp(
            _FakeResp(
                200,
                b'{"choices":[{"message":{"content":"ok"}}]}',
            )
        )
        engine.invoke(VlmRequest(image_b64=_png_b64(), prompt="x"))
        assert engine._http.captured["headers"]["Authorization"] == "Bearer sekret"

    def test_5xx_is_retryable(self, monkeypatch):
        monkeypatch.setenv("TRAINIUM_VLM_URL", "http://example.invalid/v1/chat/completions")
        from engines.vlm.trainium import TrainiumVlmEngine

        engine = TrainiumVlmEngine()
        engine._http = _FakeHttp(_FakeResp(502, b"upstream"))
        with pytest.raises(EngineError) as exc:
            engine.invoke(VlmRequest(image_b64=_png_b64(), prompt="x"))
        assert exc.value.code == "provider_error"
        assert exc.value.retryable is True

    def test_missing_choices_is_invalid_response(self, monkeypatch):
        monkeypatch.setenv("TRAINIUM_VLM_URL", "http://example.invalid/v1/chat/completions")
        from engines.vlm.trainium import TrainiumVlmEngine

        engine = TrainiumVlmEngine()
        engine._http = _FakeHttp(_FakeResp(200, b'{"oops":1}'))
        with pytest.raises(EngineError) as exc:
            engine.invoke(VlmRequest(image_b64=_png_b64(), prompt="x"))
        assert exc.value.code == "provider_invalid_response"
