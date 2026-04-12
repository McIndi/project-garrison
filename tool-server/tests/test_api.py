import os

os.environ["TOOL_SERVER_INMEMORY"] = "true"
os.environ["TOOL_SERVER_REQUIRE_TOKEN_LOOKUP"] = "false"
os.environ["TOOL_SERVER_SPAWN_MAX_DEPTH"] = "2"

from fastapi.testclient import TestClient

from app.main import app


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
