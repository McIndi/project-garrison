from contextlib import asynccontextmanager

import httpx
from fastapi import Depends, FastAPI, HTTPException

from .config import settings
from .models import MemoryWriteRequest, SpawnRequest
from .security import AuthContext, require_auth_context
from .storage import storage


def _validate_memory_key(agent_id: str, key: str) -> str:
    if key.startswith(f"agent:{agent_id}:"):
        return key
    if key.startswith("shared:memory:"):
        return key
    raise HTTPException(status_code=403, detail="Memory key outside allowed namespace")


@asynccontextmanager
async def lifespan(_: FastAPI):
    await storage.connect()
    try:
        yield
    finally:
        await storage.close()


app = FastAPI(title="garrison-tool-server", lifespan=lifespan)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/tools/memory/{key:path}")
async def post_memory(
    key: str,
    body: MemoryWriteRequest,
    auth: AuthContext = Depends(require_auth_context),
) -> dict[str, str]:
    full_key = _validate_memory_key(auth.agent_id, key)
    await storage.set_value(full_key, body.value, body.ttl_seconds)
    return {"status": "ok", "key": full_key}


@app.get("/tools/memory/{key:path}")
async def get_memory(key: str, auth: AuthContext = Depends(require_auth_context)) -> dict[str, str | None]:
    full_key = _validate_memory_key(auth.agent_id, key)
    value = await storage.get_value(full_key)
    return {"key": full_key, "value": value}


@app.delete("/tools/memory/{key:path}")
async def delete_memory(key: str, auth: AuthContext = Depends(require_auth_context)) -> dict[str, str]:
    full_key = _validate_memory_key(auth.agent_id, key)
    await storage.delete_value(full_key)
    return {"status": "deleted", "key": full_key}


@app.post("/tools/spawn")
async def spawn_agent(body: SpawnRequest, auth: AuthContext = Depends(require_auth_context)) -> dict:
    if auth.agent_class != "orchestrator":
        raise HTTPException(status_code=403, detail="Only orchestrator can spawn")
    if auth.spawn_depth >= settings.spawn_max_depth:
        raise HTTPException(status_code=403, detail="Spawn depth limit exceeded")

    payload = {
        "agent_class": body.agent_class,
        "task_context": body.task_context,
        "memory_keys": body.memory_keys,
        "parent_agent_id": auth.agent_id,
        "human_session_id": auth.human_session_id,
        "spawn_depth": auth.spawn_depth + 1,
        "root_orchestrator_id": auth.root_orchestrator_id,
    }
    last_error = ""
    for _ in range(3):
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.post(f"{settings.beeai_url}/spawn", json=payload)
            if resp.status_code == 200:
                data = resp.json()
                await storage.registry_upsert(
                    data["agent_id"],
                    {
                        "agent_id": data["agent_id"],
                        "class": body.agent_class,
                        "status": "active",
                        "spawned_by": auth.agent_id,
                        "human_session_id": auth.human_session_id,
                        "parent_agent_id": auth.agent_id,
                        "spawn_depth": str(auth.spawn_depth + 1),
                        "root_orchestrator_id": auth.root_orchestrator_id,
                    },
                )
                return data
            last_error = resp.text
        except Exception as exc:  # noqa: BLE001
            last_error = str(exc)
    raise HTTPException(status_code=503, detail=f"Spawn failed after retries: {last_error}")


@app.delete("/tools/spawn/{agent_id}")
async def delete_spawn(agent_id: str, auth: AuthContext = Depends(require_auth_context)) -> dict:
    if auth.agent_class != "orchestrator":
        raise HTTPException(status_code=403, detail="Only orchestrator can terminate")

    record = await storage.registry_get_record(agent_id)
    if not record:
        return {"agent_id": agent_id, "status": "not_found"}

    owner_root = record.get("root_orchestrator_id")
    if owner_root and owner_root != auth.root_orchestrator_id:
        raise HTTPException(status_code=403, detail="Agent is outside caller spawn tree")

    payload = {
        "agent_id": agent_id,
        "requestor_agent_id": auth.agent_id,
        "human_session_id": auth.human_session_id,
        "root_orchestrator_id": auth.root_orchestrator_id,
    }
    async with httpx.AsyncClient(timeout=10) as client:
        resp = await client.post(f"{settings.beeai_url}/terminate", json=payload)
    if resp.status_code != 200:
        raise HTTPException(status_code=502, detail="BeeAI terminate failed")

    await storage.registry_delete(agent_id)
    return {"agent_id": agent_id, "status": "terminated"}
