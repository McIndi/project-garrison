from contextlib import asynccontextmanager
from urllib.parse import urlparse

import httpx
from fastapi import Depends, FastAPI, HTTPException

from .config import settings
from .models import FetchRequest, FetchResponse, HandoffRequest, MemoryWriteRequest, SpawnRequest
from .provisioning import provisioning
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


def _scratch_key(agent_id: str, key: str) -> str:
    if not key:
        raise HTTPException(status_code=400, detail="Scratch key cannot be empty")
    return f"agent:{agent_id}:scratch:{key}"


def _validate_fetch_url(url: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme not in {"http", "https"}:
        raise HTTPException(status_code=400, detail="Only http/https URLs are allowed")
    if not parsed.netloc:
        raise HTTPException(status_code=400, detail="Fetch URL must include host")


@app.post("/tools/memory/{key:path}")
async def post_memory(
    key: str,
    body: MemoryWriteRequest,
    auth: AuthContext = Depends(require_auth_context),
) -> dict[str, str]:
    full_key = _validate_memory_key(auth.agent_id, key)
    await storage.set_value(full_key, body.value, body.ttl_seconds)
    return {"status": "ok", "key": full_key}


@app.post("/tools/scratch/{key:path}")
async def post_scratch(
    key: str,
    body: MemoryWriteRequest,
    auth: AuthContext = Depends(require_auth_context),
) -> dict[str, str]:
    full_key = _scratch_key(auth.agent_id, key)
    # Scratchpad is private and always short-lived by policy.
    ttl = body.ttl_seconds if body.ttl_seconds is not None else 3600
    await storage.set_value(full_key, body.value, ttl)
    return {"status": "ok", "key": full_key}


@app.get("/tools/scratch/{key:path}")
async def get_scratch(key: str, auth: AuthContext = Depends(require_auth_context)) -> dict[str, str | None]:
    full_key = _scratch_key(auth.agent_id, key)
    value = await storage.get_value(full_key)
    return {"key": full_key, "value": value}


@app.delete("/tools/scratch/{key:path}")
async def delete_scratch(key: str, auth: AuthContext = Depends(require_auth_context)) -> dict[str, str]:
    full_key = _scratch_key(auth.agent_id, key)
    await storage.delete_value(full_key)
    return {"status": "deleted", "key": full_key}


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


@app.get("/tools/registry")
async def get_registry(_: AuthContext = Depends(require_auth_context)) -> dict:
    agents = await storage.registry_list()
    return {"agents": agents}


@app.post("/tools/fetch", response_model=FetchResponse)
async def fetch_url(body: FetchRequest, _: AuthContext = Depends(require_auth_context)) -> FetchResponse:
    _validate_fetch_url(body.url)
    method = body.method.upper()
    if method not in {"GET", "POST", "PUT", "PATCH", "DELETE", "HEAD"}:
        raise HTTPException(status_code=400, detail="Unsupported HTTP method")

    req_headers = dict(body.headers)

    try:
        async with httpx.AsyncClient(timeout=10, follow_redirects=True) as client:
            resp = await client.request(
                method=method,
                url=body.url,
                headers=req_headers,
                content=body.body,
            )
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail=f"Fetch failed: {exc}") from exc

    return FetchResponse(
        status=resp.status_code,
        body=resp.text,
        content_type=resp.headers.get("content-type", "application/octet-stream"),
    )


@app.post("/tools/handoff")
async def write_handoff(body: HandoffRequest, auth: AuthContext = Depends(require_auth_context)) -> dict[str, str]:
    if body.from_agent_id != auth.agent_id:
        raise HTTPException(status_code=403, detail="from_agent_id must match authenticated agent")

    handoff = {
        "from_agent_id": body.from_agent_id,
        "to_agent_class": body.to_agent_class,
        "task_context": body.task_context,
        "artifacts": [a.model_dump() for a in body.artifacts],
        "memory_keys": body.memory_keys,
        "reasoning_summary": body.reasoning_summary,
        "priority": body.priority,
        "human_session_id": auth.human_session_id,
        "created_at": storage.utc_now_iso(),
    }

    await storage.write_handoff(body.from_agent_id, handoff)

    if not settings.use_inmemory:
        try:
            client = provisioning._mongo_client()
            db = client[f"agent_{body.from_agent_id}"]
            db["handoffs"].insert_one(handoff)
        except Exception as exc:  # noqa: BLE001
            raise HTTPException(status_code=503, detail=f"Mongo handoff write failed: {exc}") from exc

    return {"status": "ok", "key": f"registry:handoff:{body.from_agent_id}"}


@app.post("/tools/spawn")
async def spawn_agent(body: SpawnRequest, auth: AuthContext = Depends(require_auth_context)) -> dict:
    if auth.agent_class != "orchestrator":
        raise HTTPException(status_code=403, detail="Only orchestrator can spawn")
    if auth.spawn_depth >= settings.spawn_max_depth:
        raise HTTPException(status_code=403, detail="Spawn depth limit exceeded")

    human_session_id = auth.human_session_id or provisioning.system_session_id()
    creds = await provisioning.issue_spawn_credentials(body.agent_class)

    payload = {
        "agent_class": body.agent_class,
        "task_context": body.task_context,
        "memory_keys": body.memory_keys,
        "parent_agent_id": auth.agent_id,
        "human_session_id": human_session_id,
        "spawn_depth": auth.spawn_depth + 1,
        "root_orchestrator_id": auth.root_orchestrator_id,
        "vault_role_id": creds.role_id,
        "vault_secret_id": creds.secret_id,
    }
    last_error = ""
    for _ in range(3):
        try:
            async with httpx.AsyncClient(timeout=10) as client:
                resp = await client.post(f"{settings.beeai_url}/spawn", json=payload)
            if resp.status_code == 200:
                data = resp.json()
                provisioning.provision_agent_collections(data["agent_id"])
                await storage.registry_upsert(
                    data["agent_id"],
                    {
                        "agent_id": data["agent_id"],
                        "class": body.agent_class,
                        "status": "active",
                        "spawned_by": auth.agent_id,
                        "human_session_id": human_session_id,
                        "parent_agent_id": auth.agent_id,
                        "spawn_depth": str(auth.spawn_depth + 1),
                        "root_orchestrator_id": auth.root_orchestrator_id,
                        "vault_token_accessor": creds.token_accessor,
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

    accessor = record.get("vault_token_accessor")
    if accessor:
        await provisioning.revoke_accessor(accessor)

    await storage.registry_delete(agent_id)
    return {"agent_id": agent_id, "status": "terminated"}
