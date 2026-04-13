import asyncio
import importlib.util
import os
from pathlib import Path

os.environ["GARRISON_ORCHESTRATE_BEARER_TOKEN"] = "test-orchestrate-token"


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
    pipeline.orchestrate_required_roles = set()
    pipeline.orchestrate_required_groups = set()
    pipeline.orchestrate_require_user_claims = False
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
    pipeline.orchestrate_required_roles = set()
    pipeline.orchestrate_required_groups = set()
    pipeline.orchestrate_require_user_claims = False

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


def test_inlet_propagates_user_identity_claims(monkeypatch) -> None:
    pipeline = Pipeline()
    pipeline.orchestrate_enabled = False

    async def fake_emit(stage, body, user):
        return None

    monkeypatch.setattr(pipeline, "_emit_otel_log", fake_emit)

    body = {"messages": [{"role": "user", "content": "hello"}], "metadata": {}}
    user = {
        "session_id": "human-sess-claims",
        "sub": "user-123",
        "iss": "https://keycloak.local/realms/garrison",
        "roles": ["garrison-orchestrator"],
        "groups": ["garrison-orchestrators"],
    }
    result = asyncio.run(pipeline.inlet(body, user))

    assert result["metadata"]["user_sub"] == "user-123"
    assert result["metadata"]["user_issuer"] == "https://keycloak.local/realms/garrison"
    assert result["metadata"]["user_roles"] == ["garrison-orchestrator"]
    assert result["metadata"]["user_groups"] == ["garrison-orchestrators"]


def test_outlet_ignores_otel_failure() -> None:
    pipeline = Pipeline()
    pipeline.otel_enabled = True

    async def fake_emit(stage, body, user):
        raise RuntimeError("collector down")

    pipeline._emit_otel_log = fake_emit  # type: ignore[method-assign]

    body = {"messages": [{"role": "assistant", "content": "ok"}], "metadata": {}}
    result = asyncio.run(pipeline.outlet(body, {"session_id": "human-sess-4"}))

    assert result is body


def test_inlet_sets_orchestration_error_when_bearer_missing(monkeypatch) -> None:
    pipeline = Pipeline()
    pipeline.orchestrate_bearer_token = ""

    async def fake_emit(stage, body, user):
        return None

    monkeypatch.setattr(pipeline, "_emit_otel_log", fake_emit)

    body = {"messages": [{"role": "user", "content": "run task"}], "metadata": {}}
    result = asyncio.run(pipeline.inlet(body, {"session_id": "human-sess-5"}))

    assert "garrison_orchestration_error" in result["metadata"]
    assert "GARRISON_ORCHESTRATE_BEARER_TOKEN" in result["metadata"]["garrison_orchestration_error"]


def test_inlet_sets_orchestration_error_when_user_not_authorized(monkeypatch) -> None:
    pipeline = Pipeline()
    pipeline.orchestrate_required_roles = {"garrison-orchestrator"}
    pipeline.orchestrate_required_groups = {"garrison-orchestrators"}
    pipeline.orchestrate_require_user_claims = True

    async def fake_emit(stage, body, user):
        return None

    monkeypatch.setattr(pipeline, "_emit_otel_log", fake_emit)

    body = {"messages": [{"role": "user", "content": "run task"}], "metadata": {}}
    user = {
        "session_id": "human-sess-6",
        "sub": "user-456",
        "iss": "https://keycloak.local/realms/garrison",
        "roles": ["viewer"],
        "groups": ["analysts"],
    }
    result = asyncio.run(pipeline.inlet(body, user))

    assert "garrison_orchestration_error" in result["metadata"]
    assert "not authorized" in result["metadata"]["garrison_orchestration_error"]


def test_inlet_sets_orchestration_error_when_required_claims_missing(monkeypatch) -> None:
    pipeline = Pipeline()
    pipeline.orchestrate_required_roles = set()
    pipeline.orchestrate_required_groups = set()
    pipeline.orchestrate_require_user_claims = True

    async def fake_emit(stage, body, user):
        return None

    monkeypatch.setattr(pipeline, "_emit_otel_log", fake_emit)

    body = {"messages": [{"role": "user", "content": "run task"}], "metadata": {}}
    user = {
        "session_id": "human-sess-7",
        "roles": ["garrison-orchestrator"],
    }
    result = asyncio.run(pipeline.inlet(body, user))

    assert "garrison_orchestration_error" in result["metadata"]
    assert "sub/iss" in result["metadata"]["garrison_orchestration_error"]
