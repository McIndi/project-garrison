import os
import hashlib
import json

os.environ["TOOL_SERVER_INMEMORY"] = "true"
os.environ["TOOL_SERVER_REQUIRE_TOKEN_LOOKUP"] = "false"
os.environ["TOOL_SERVER_SPAWN_MAX_DEPTH"] = "2"
os.environ["TOOL_SERVER_FETCH_PROXY_URL"] = "http://proxy.local:8088"
os.environ["TOOL_SERVER_FETCH_REQUIRE_PROXY"] = "true"
os.environ["TOOL_SERVER_OTEL_ENABLED"] = "false"

from fastapi.testclient import TestClient
from fastapi import HTTPException

from app.main import app
from app.storage import storage


client = TestClient(app)


BASE_HEADERS = {
    "Authorization": "Bearer demo-token",
    "x-agent-id": "agent-root",
    "x-agent-class": "orchestrator",
    "x-human-session-id": "human-123",
    "x-spawn-depth": "0",
    "x-root-orchestrator-id": "agent-root",
}


def test_health() -> None:
    resp = client.get("/health")
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_memory_namespace_rejects_bad_key() -> None:
    resp = client.post("/tools/memory/not-allowed", headers=BASE_HEADERS, json={"value": "x"})
    assert resp.status_code == 403


def test_memory_namespace_accepts_agent_key() -> None:
    key = "agent:agent-root:state"
    resp = client.post(f"/tools/memory/{key}", headers=BASE_HEADERS, json={"value": "ok"})
    assert resp.status_code == 200
    read = client.get(f"/tools/memory/{key}", headers=BASE_HEADERS)
    assert read.status_code == 200
    assert read.json()["value"] == "ok"


def test_spawn_requires_orchestrator() -> None:
    headers = dict(BASE_HEADERS)
    headers["x-agent-class"] = "rag"
    resp = client.post(
        "/tools/spawn",
        headers=headers,
        json={"agent_class": "rag", "task_context": "ctx", "memory_keys": []},
    )
    assert resp.status_code == 403


def test_spawn_depth_limit_enforced() -> None:
    headers = dict(BASE_HEADERS)
    headers["x-spawn-depth"] = "2"
    resp = client.post(
        "/tools/spawn",
        headers=headers,
        json={"agent_class": "rag", "task_context": "ctx", "memory_keys": []},
    )
    assert resp.status_code == 403


def test_spawn_retries_with_backoff(monkeypatch) -> None:
    async def fake_issue_spawn_credentials(_: str):
        class Creds:
            role_id = "role-id"
            secret_id = "secret-id"
            token_accessor = "acc-123"

        return Creds()

    class DummyClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def post(self, _url, json):
            raise RuntimeError("beeai unavailable")

    sleeps: list[float] = []

    async def fake_sleep(seconds: float):
        sleeps.append(seconds)

    monkeypatch.setattr("app.main.provisioning.issue_spawn_credentials", fake_issue_spawn_credentials)
    monkeypatch.setattr("app.main.httpx.AsyncClient", lambda timeout: DummyClient())
    monkeypatch.setattr("app.main.asyncio.sleep", fake_sleep)

    resp = client.post(
        "/tools/spawn",
        headers=BASE_HEADERS,
        json={"agent_class": "rag", "task_context": "ctx", "memory_keys": []},
    )
    assert resp.status_code == 503
    assert sleeps == [0.2, 0.4]


def test_nested_spawn_requires_root_orchestrator_header() -> None:
    headers = dict(BASE_HEADERS)
    headers["x-spawn-depth"] = "1"
    headers.pop("x-root-orchestrator-id")
    resp = client.post(
        "/tools/spawn",
        headers=headers,
        json={"agent_class": "rag", "task_context": "ctx", "memory_keys": []},
    )
    assert resp.status_code == 400


def test_delete_rejects_other_spawn_tree(monkeypatch) -> None:
    async def fake_registry_get_record(_: str):
        return {
            "agent_id": "agt-abc",
            "root_orchestrator_id": "other-root",
        }

    monkeypatch.setattr("app.main.storage.registry_get_record", fake_registry_get_record)

    resp = client.delete("/tools/spawn/agt-abc", headers=BASE_HEADERS)
    assert resp.status_code == 403


def test_missing_human_session_gets_system_id(monkeypatch) -> None:
    headers = dict(BASE_HEADERS)
    headers.pop("x-human-session-id")

    async def fake_issue_spawn_credentials(_: str):
        class Creds:
            role_id = "role-id"
            secret_id = "secret-id"
            token_accessor = "acc-123"

        return Creds()

    async def fake_post(url, json):
        class Resp:
            status_code = 200

            @staticmethod
            def json():
                return {"agent_id": "agt-test", "status": "spawned"}

        return Resp()

    class DummyClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        post = staticmethod(fake_post)

    monkeypatch.setattr("app.main.provisioning.issue_spawn_credentials", fake_issue_spawn_credentials)
    monkeypatch.setattr("app.main.provisioning.provision_agent_collections", lambda _: None)
    monkeypatch.setattr("app.main.httpx.AsyncClient", lambda timeout: DummyClient())

    resp = client.post(
        "/tools/spawn",
        headers=headers,
        json={"agent_class": "rag", "task_context": "ctx", "memory_keys": []},
    )
    assert resp.status_code == 200


def test_orchestrate_defaults_to_rag(monkeypatch) -> None:
    captured = {}

    async def fake_issue_spawn_credentials(_: str):
        class Creds:
            role_id = "role-id"
            secret_id = "secret-id"
            token_accessor = "acc-123"

        return Creds()

    async def fake_post(url, json):
        captured["payload"] = json

        class Resp:
            status_code = 200

            @staticmethod
            def json():
                return {"agent_id": "agt-rag-1", "status": "spawned"}

        return Resp()

    class DummyClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        post = staticmethod(fake_post)

    monkeypatch.setattr("app.main.provisioning.issue_spawn_credentials", fake_issue_spawn_credentials)
    monkeypatch.setattr("app.main.provisioning.provision_agent_collections", lambda _: None)
    monkeypatch.setattr("app.main.httpx.AsyncClient", lambda timeout: DummyClient())

    resp = client.post(
        "/orchestrate",
        headers=BASE_HEADERS,
        json={"request_text": "summarize docs", "human_session_id": "human-123"},
    )
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["status"] == "accepted"
    assert payload["spawned_agent_id"] == "agt-rag-1"
    assert captured["payload"]["agent_class"] == "rag"


def test_orchestrate_propagates_body_human_session_id(monkeypatch) -> None:
    headers = dict(BASE_HEADERS)
    headers.pop("x-human-session-id")
    captured = {}

    async def fake_issue_spawn_credentials(_: str):
        class Creds:
            role_id = "role-id"
            secret_id = "secret-id"
            token_accessor = "acc-123"

        return Creds()

    async def fake_post(url, json):
        captured["payload"] = json

        class Resp:
            status_code = 200

            @staticmethod
            def json():
                return {"agent_id": "agt-rag-2", "status": "spawned"}

        return Resp()

    class DummyClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        post = staticmethod(fake_post)

    monkeypatch.setattr("app.main.provisioning.issue_spawn_credentials", fake_issue_spawn_credentials)
    monkeypatch.setattr("app.main.provisioning.provision_agent_collections", lambda _: None)
    monkeypatch.setattr("app.main.httpx.AsyncClient", lambda timeout: DummyClient())

    resp = client.post(
        "/orchestrate",
        headers=headers,
        json={"request_text": "summarize docs", "human_session_id": "human-body-456"},
    )
    assert resp.status_code == 200
    assert captured["payload"]["human_session_id"] == "human-body-456"


def test_orchestrate_handles_locally_for_orchestrator_preference() -> None:
    resp = client.post(
        "/orchestrate",
        headers=BASE_HEADERS,
        json={
            "request_text": "plan task",
            "human_session_id": "human-123",
            "preferred_agent_class": "orchestrator",
        },
    )
    assert resp.status_code == 200
    payload = resp.json()
    assert payload["status"] == "completed"
    assert payload["spawned_agent_id"] is None


def test_orchestrate_requires_orchestrator_class() -> None:
    headers = dict(BASE_HEADERS)
    headers["x-agent-class"] = "rag"

    resp = client.post(
        "/orchestrate",
        headers=headers,
        json={"request_text": "summarize docs", "human_session_id": "human-123"},
    )
    assert resp.status_code == 403


def test_delete_revokes_accessor(monkeypatch) -> None:
    async def fake_registry_get_record(_: str):
        return {
            "agent_id": "agt-abc",
            "root_orchestrator_id": "agent-root",
            "vault_token_accessor": "acc-xyz",
        }

    async def fake_post(url, json):
        class Resp:
            status_code = 200

            text = "ok"

        return Resp()

    class DummyClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        post = staticmethod(fake_post)

    revoked = {"called": False}

    async def fake_revoke_accessor(accessor: str):
        revoked["called"] = accessor == "acc-xyz"

    async def fake_registry_delete(_: str):
        return None

    monkeypatch.setattr("app.main.storage.registry_get_record", fake_registry_get_record)
    monkeypatch.setattr("app.main.storage.registry_delete", fake_registry_delete)
    monkeypatch.setattr("app.main.httpx.AsyncClient", lambda timeout: DummyClient())
    monkeypatch.setattr("app.main.provisioning.revoke_accessor", fake_revoke_accessor)

    resp = client.delete("/tools/spawn/agt-abc", headers=BASE_HEADERS)
    assert resp.status_code == 200
    assert revoked["called"] is True


def test_scratch_roundtrip() -> None:
    key = "notes/current"
    write = client.post(f"/tools/scratch/{key}", headers=BASE_HEADERS, json={"value": "draft"})
    assert write.status_code == 200
    read = client.get(f"/tools/scratch/{key}", headers=BASE_HEADERS)
    assert read.status_code == 200
    assert read.json()["value"] == "draft"


def test_registry_endpoint_returns_agents() -> None:
    resp = client.get("/tools/registry", headers=BASE_HEADERS)
    assert resp.status_code == 200
    assert "agents" in resp.json()
    assert isinstance(resp.json()["agents"], list)


def test_registry_requires_token_lookup_when_enabled(monkeypatch) -> None:
    called = {"value": False}

    async def fake_lookup(_: str):
        called["value"] = True
        return {
            "data": {
                "id": "tok",
                "display_name": "token",
                "policies": ["default", "garrison-base", "garrison-orchestrator"],
                "meta": {"agent_id": "agent-root", "agent_class": "orchestrator"},
            }
        }

    monkeypatch.setattr("app.security.settings.require_token_lookup", True)
    monkeypatch.setattr("app.security._lookup_vault_token", fake_lookup)

    resp = client.get("/tools/registry", headers=BASE_HEADERS)
    assert resp.status_code == 200
    assert called["value"] is True


def test_security_defaults_disable_identity_fallbacks() -> None:
    from app.config import settings

    assert settings.require_token_metadata_contract is True
    assert settings.allow_header_identity_fallback is False
    assert settings.allow_root_token_fallback is False


def test_registry_rejects_when_token_lookup_fails(monkeypatch) -> None:
    async def fake_lookup(_: str):
        raise HTTPException(status_code=401, detail="Vault token lookup failed")

    monkeypatch.setattr("app.security.settings.require_token_lookup", True)
    monkeypatch.setattr("app.security._lookup_vault_token", fake_lookup)

    resp = client.get("/tools/registry", headers=BASE_HEADERS)
    assert resp.status_code == 401


def test_registry_rejects_agent_class_mismatch_from_token_claims(monkeypatch) -> None:
    async def fake_lookup(_: str):
        return {
            "data": {
                "display_name": "token",
                "policies": ["default", "garrison-base", "garrison-rag"],
                "meta": {"agent_id": "agent-root", "agent_class": "rag"},
            }
        }

    monkeypatch.setattr("app.security.settings.require_token_lookup", True)
    monkeypatch.setattr("app.security.settings.enforce_token_identity_binding", True)
    monkeypatch.setattr("app.security._lookup_vault_token", fake_lookup)

    resp = client.get("/tools/registry", headers=BASE_HEADERS)
    assert resp.status_code == 403


def test_registry_rejects_agent_id_mismatch_from_token_claims(monkeypatch) -> None:
    async def fake_lookup(_: str):
        return {
            "data": {
                "display_name": "token",
                "policies": ["default", "garrison-base", "garrison-orchestrator"],
                "meta": {"agent_id": "agent-other", "agent_class": "orchestrator"},
            }
        }

    monkeypatch.setattr("app.security.settings.require_token_lookup", True)
    monkeypatch.setattr("app.security.settings.enforce_token_identity_binding", True)
    monkeypatch.setattr("app.security._lookup_vault_token", fake_lookup)

    resp = client.get("/tools/registry", headers=BASE_HEADERS)
    assert resp.status_code == 403


def test_registry_rejects_missing_claims_when_fallback_disabled(monkeypatch) -> None:
    async def fake_lookup(_: str):
        return {
            "data": {
                "display_name": "token",
                "policies": ["default"],
                "meta": {},
            }
        }

    monkeypatch.setattr("app.security.settings.require_token_lookup", True)
    monkeypatch.setattr("app.security.settings.enforce_token_identity_binding", True)
    monkeypatch.setattr("app.security.settings.allow_header_identity_fallback", False)
    monkeypatch.setattr("app.security.settings.allow_root_token_fallback", False)
    monkeypatch.setattr("app.security._lookup_vault_token", fake_lookup)

    resp = client.get("/tools/registry", headers=BASE_HEADERS)
    assert resp.status_code == 403


def test_registry_rejects_missing_agent_class_metadata_when_contract_required(monkeypatch) -> None:
    async def fake_lookup(_: str):
        return {
            "data": {
                "display_name": "token",
                "policies": ["default", "garrison-base", "garrison-orchestrator"],
                "meta": {"agent_id": "agent-root"},
            }
        }

    monkeypatch.setattr("app.security.settings.require_token_lookup", True)
    monkeypatch.setattr("app.security.settings.enforce_token_identity_binding", True)
    monkeypatch.setattr("app.security.settings.require_token_metadata_contract", True)
    monkeypatch.setattr("app.security.settings.allow_header_identity_fallback", False)
    monkeypatch.setattr("app.security._lookup_vault_token", fake_lookup)

    resp = client.get("/tools/registry", headers=BASE_HEADERS)
    assert resp.status_code == 403


def test_fetch_rejects_invalid_scheme() -> None:
    resp = client.post(
        "/tools/fetch",
        headers=BASE_HEADERS,
        json={"url": "ftp://example.com/file.txt", "method": "GET"},
    )
    assert resp.status_code == 400


def test_fetch_rejects_internal_service_hostname() -> None:
    resp = client.post(
        "/tools/fetch",
        headers=BASE_HEADERS,
        json={"url": "http://vault:8200/v1/sys/health", "method": "GET"},
    )
    assert resp.status_code == 400


def test_fetch_rejects_private_ip(monkeypatch) -> None:
    monkeypatch.setattr(
        "app.main.socket.getaddrinfo",
        lambda host, port, type: [(2, 1, 6, "", ("10.0.0.15", int(port)))],
    )

    resp = client.post(
        "/tools/fetch",
        headers=BASE_HEADERS,
        json={"url": "http://example.com/resource", "method": "GET"},
    )
    assert resp.status_code == 400


def test_fetch_success(monkeypatch) -> None:
    captured = {}

    monkeypatch.setattr(
        "app.main.socket.getaddrinfo",
        lambda host, port, type: [(2, 1, 6, "", ("93.184.216.34", int(port)))],
    )

    async def fake_request(method, url, headers, content):
        class Resp:
            status_code = 200
            text = "ok"
            headers = {"content-type": "text/plain"}

        return Resp()

    class DummyClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        request = staticmethod(fake_request)

    def fake_builder():
        captured["proxy"] = "http://proxy.local:8088"
        return DummyClient()

    monkeypatch.setattr("app.main._build_fetch_client", fake_builder)

    resp = client.post(
        "/tools/fetch",
        headers=BASE_HEADERS,
        json={"url": "http://example.com", "method": "GET"},
    )
    assert resp.status_code == 200
    assert resp.json()["status"] == 200
    assert resp.json()["body"] == "ok"
    assert captured["proxy"] == "http://proxy.local:8088"


def test_fetch_rejects_when_proxy_required_but_not_configured(monkeypatch) -> None:
    monkeypatch.setattr("app.main.settings.fetch_require_proxy", True)
    monkeypatch.setattr("app.main.settings.fetch_proxy_url", "")

    resp = client.post(
        "/tools/fetch",
        headers=BASE_HEADERS,
        json={"url": "http://example.com", "method": "GET"},
    )
    assert resp.status_code == 503


def test_handoff_write_requires_matching_agent() -> None:
    resp = client.post(
        "/tools/handoff",
        headers=BASE_HEADERS,
        json={
            "from_agent_id": "other-agent",
            "to_agent_class": "rag",
            "task_context": "review docs",
            "artifacts": [],
            "memory_keys": [],
            "reasoning_summary": "handoff",
            "priority": "normal",
        },
    )
    assert resp.status_code == 403


def test_handoff_write_success() -> None:
    payload = {
        "from_agent_id": "agent-root",
        "to_agent_class": "rag",
        "task_context": "review docs",
        "artifacts": [{"type": "note", "ref": "obj-1"}],
        "memory_keys": ["shared:memory:brief"],
        "reasoning_summary": "Please summarize source",
        "priority": "high",
    }

    resp = client.post("/tools/handoff", headers=BASE_HEADERS, json=payload)
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"
    handoff_key = "registry:handoff:agent-root"
    assert handoff_key in storage._mem_kv


def test_summarize_extracts_key_points() -> None:
    content = (
        "Project Garrison provisions governed agents. "
        "It enforces policy boundaries and records audit evidence. "
        "Phase four expands tool coverage."
    )
    resp = client.post(
        "/tools/summarize",
        headers=BASE_HEADERS,
        json={"content": content, "max_tokens": 80, "format": "bullets"},
    )
    assert resp.status_code == 200
    payload = resp.json()
    assert isinstance(payload["key_points"], list)
    assert len(payload["key_points"]) >= 1


def test_encrypt_and_decrypt_transit(monkeypatch) -> None:
    async def fake_post(url, headers, json):
        class Resp:
            status_code = 200
            text = "ok"

            @staticmethod
            def json():
                if "/encrypt/" in url:
                    return {"data": {"ciphertext": "vault:v1:abc"}}
                return {"data": {"plaintext": "aGVsbG8="}}

        return Resp()

    class DummyClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        post = staticmethod(fake_post)

    monkeypatch.setattr("app.main.httpx.AsyncClient", lambda timeout: DummyClient())

    enc = client.post(
        "/tools/encrypt",
        headers=BASE_HEADERS,
        json={"plaintext": "aGVsbG8=", "key": "agent-payload"},
    )
    assert enc.status_code == 200
    assert enc.json()["ciphertext"].startswith("vault:v1:")

    dec = client.post(
        "/tools/decrypt",
        headers=BASE_HEADERS,
        json={"ciphertext": "vault:v1:abc", "key": "agent-payload"},
    )
    assert dec.status_code == 200
    assert dec.json()["plaintext"] == "aGVsbG8="


def test_search_inmemory_returns_empty() -> None:
    resp = client.post(
        "/tools/search",
        headers=BASE_HEADERS,
        json={"query": "garrison", "corpus": "shared_artifacts.objects", "top_k": 5},
    )
    assert resp.status_code == 200
    assert resp.json()["results"] == []


def test_search_rejects_disallowed_corpus() -> None:
    resp = client.post(
        "/tools/search",
        headers=BASE_HEADERS,
        json={"query": "garrison", "corpus": "admin.system.users", "top_k": 5},
    )
    assert resp.status_code == 403


def test_search_rejects_whitespace_query() -> None:
    resp = client.post(
        "/tools/search",
        headers=BASE_HEADERS,
        json={"query": "   ", "corpus": "shared_artifacts.objects", "top_k": 5},
    )
    assert resp.status_code == 422


def test_audit_payload_hash_mode(monkeypatch) -> None:
    monkeypatch.setattr("app.main.settings.audit_payload_mode", "hash-only")

    captured = {}

    def fake_print(message: str):
        captured["message"] = message

    monkeypatch.setattr("builtins.print", fake_print)

    body = {"value": "secret"}
    resp = client.post("/tools/memory/agent:agent-root:audit", headers=BASE_HEADERS, json=body)
    assert resp.status_code == 200
    event = json.loads(captured["message"])
    payload_hash = event["request_payload"]
    assert len(payload_hash) == 64
    int(payload_hash, 16)


def test_audit_payload_redacted_mode(monkeypatch) -> None:
    monkeypatch.setattr("app.main.settings.audit_payload_mode", "redacted")

    captured = {}

    def fake_print(message: str):
        captured["message"] = message

    monkeypatch.setattr("builtins.print", fake_print)

    resp = client.post(
        "/tools/memory/agent:agent-root:auth",
        headers=BASE_HEADERS,
        json={"value": "ok", "token": "super-secret-token"},
    )
    assert resp.status_code == 200
    assert "[REDACTED]" in captured["message"]


def test_audit_ingest_rejects_missing_or_bad_token(monkeypatch) -> None:
    monkeypatch.setattr("app.main.settings.audit_ingest_token", "expected-token")

    missing = client.post("/internal/audit/ingest/vault", data='{"msg":"x"}')
    assert missing.status_code == 403

    wrong = client.post(
        "/internal/audit/ingest/vault",
        headers={"x-audit-ingest-token": "wrong-token"},
        data='{"msg":"x"}',
    )
    assert wrong.status_code == 403


def test_audit_ingest_rejects_when_server_token_not_configured(monkeypatch) -> None:
    monkeypatch.setattr("app.main.settings.audit_ingest_token", "")

    resp = client.post(
        "/internal/audit/ingest/vault",
        headers={"x-audit-ingest-token": "anything"},
        data='{"msg":"x"}',
    )
    assert resp.status_code == 503


def test_audit_ingest_rejects_unknown_source(monkeypatch) -> None:
    monkeypatch.setattr("app.main.settings.audit_ingest_token", "expected-token")

    resp = client.post(
        "/internal/audit/ingest/unknown",
        headers={"x-audit-ingest-token": "expected-token"},
        data='{"msg":"x"}',
    )
    assert resp.status_code == 400


def test_audit_ingest_parses_json_lines_and_persists(monkeypatch) -> None:
    monkeypatch.setattr("app.main.settings.audit_ingest_token", "expected-token")
    monkeypatch.setattr("app.main.settings.use_inmemory", False)

    captured = {"docs": []}

    class FakeCollection:
        def insert_many(self, docs):
            captured["docs"] = docs

    class FakeDatabase:
        def __getitem__(self, _name):
            return FakeCollection()

    class FakeMongo:
        def __getitem__(self, _name):
            return FakeDatabase()

    monkeypatch.setattr("app.main.provisioning._mongo_client", lambda: FakeMongo())

    payload = "\n".join(
        [
            '{"log":"{\\"event\\":\\"vault\\"}"}',
            '{"log":"plain text line"}',
            "raw line fallback",
        ]
    )
    resp = client.post(
        "/internal/audit/ingest/vault",
        headers={"x-audit-ingest-token": "expected-token", "content-type": "text/plain"},
        data=payload,
    )

    assert resp.status_code == 200
    assert resp.json()["ingested"] == 3
    assert len(captured["docs"]) == 3
    assert captured["docs"][0]["source"] == "vault"
    assert captured["docs"][0]["parsed_log"] == {"event": "vault"}
    assert captured["docs"][1]["parsed_log"] is None
    assert captured["docs"][2]["record"] == {"log": "raw line fallback"}


def test_audit_middleware_emits_otel_when_enabled(monkeypatch) -> None:
    emitted = {"event": None}

    async def fake_emit(event: dict):
        emitted["event"] = event

    monkeypatch.setattr("app.main.settings.otel_enabled", True)
    monkeypatch.setattr("app.main._emit_otel_log", fake_emit)

    resp = client.post(
        "/tools/memory/agent:agent-root:otel",
        headers=BASE_HEADERS,
        json={"value": "ok"},
    )
    assert resp.status_code == 200
    assert emitted["event"] is not None
    assert emitted["event"]["tool_name"] == "/tools/memory/agent:agent-root:otel"


def test_audit_middleware_ignores_otel_failures(monkeypatch) -> None:
    async def fake_emit(_: dict):
        raise RuntimeError("otel down")

    monkeypatch.setattr("app.main.settings.otel_enabled", True)
    monkeypatch.setattr("app.main._emit_otel_log", fake_emit)

    resp = client.post(
        "/tools/memory/agent:agent-root:otel-fail",
        headers=BASE_HEADERS,
        json={"value": "ok"},
    )
    assert resp.status_code == 200
