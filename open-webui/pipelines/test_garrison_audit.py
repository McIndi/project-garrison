import asyncio
import importlib.util
from pathlib import Path


def _load_pipeline_module():
    file_path = Path(__file__).parent / "garrison_audit.py"
    spec = importlib.util.spec_from_file_location("garrison_audit", file_path)
    module = importlib.util.module_from_spec(spec)
    assert spec and spec.loader
    spec.loader.exec_module(module)
    return module


MODULE = _load_pipeline_module()
Pipeline = MODULE.Pipeline


def test_extract_request_text_uses_last_user_message() -> None:
    pipeline = Pipeline()
    body = {
        "messages": [
            {"role": "system", "content": "rules"},
            {"role": "user", "content": "first"},
            {"role": "assistant", "content": "ack"},
            {"role": "user", "content": "latest question"},
        ]
    }
    assert pipeline._extract_request_text(body) == "latest question"


def test_inlet_calls_orchestrate_and_sets_metadata(monkeypatch) -> None:
    pipeline = Pipeline()
    captured = {}

    async def fake_post(url, headers, json):
        captured["url"] = url
        captured["headers"] = headers
        captured["json"] = json

        class Resp:
            def raise_for_status(self):
                return None

            @staticmethod
            def json():
                return {
                    "workflow_id": "wf-test",
                    "status": "accepted",
                    "spawned_agent_id": "agt-123",
                    "result_summary": "Delegated request to rag agent.",
                }

        return Resp()

    class DummyClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        post = staticmethod(fake_post)

    monkeypatch.setattr(MODULE.httpx, "AsyncClient", lambda timeout: DummyClient())

    body = {"messages": [{"role": "user", "content": "summarize this"}], "metadata": {}}
    result = asyncio.run(pipeline.inlet(body, {"session_id": "human-sess-1"}))

    assert captured["url"].endswith("/orchestrate")
    assert captured["json"]["request_text"] == "summarize this"
    assert captured["json"]["human_session_id"] == "human-sess-1"
    assert result["metadata"]["garrison_orchestration"]["workflow_id"] == "wf-test"


def test_inlet_orchestrate_failure_is_non_fatal(monkeypatch) -> None:
    pipeline = Pipeline()

    async def fake_post(url, headers, json):
        raise RuntimeError("network down")

    class DummyClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        post = staticmethod(fake_post)

    monkeypatch.setattr(MODULE.httpx, "AsyncClient", lambda timeout: DummyClient())

    body = {"messages": [{"role": "user", "content": "summarize this"}], "metadata": {}}
    result = asyncio.run(pipeline.inlet(body, {"session_id": "human-sess-2"}))

    assert "garrison_orchestration_error" in result["metadata"]


def test_inlet_emits_otel_when_enabled(monkeypatch) -> None:
    pipeline = Pipeline()
    pipeline.otel_enabled = True
    captured = {"stage": None}

    async def fake_emit(stage, body, user):
        captured["stage"] = stage

    async def fake_maybe_orchestrate(body, human_session_id):
        return None

    monkeypatch.setattr(pipeline, "_emit_otel_log", fake_emit)
    monkeypatch.setattr(pipeline, "_maybe_orchestrate", fake_maybe_orchestrate)

    body = {"messages": [{"role": "user", "content": "hello"}], "metadata": {}}
    result = asyncio.run(pipeline.inlet(body, {"session_id": "human-sess-3"}))

    assert result["metadata"]["human_session_id"] == "human-sess-3"
    assert captured["stage"] == "inlet"


def test_outlet_ignores_otel_failure() -> None:
    pipeline = Pipeline()
    pipeline.otel_enabled = True

    async def fake_emit(stage, body, user):
        raise RuntimeError("collector down")

    pipeline._emit_otel_log = fake_emit  # type: ignore[method-assign]

    body = {"messages": [{"role": "assistant", "content": "ok"}], "metadata": {}}
    result = asyncio.run(pipeline.outlet(body, {"session_id": "human-sess-4"}))

    assert result is body
