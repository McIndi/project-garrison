import uuid

from fastapi import FastAPI, HTTPException
from pydantic import BaseModel, Field


class SpawnRequest(BaseModel):
    agent_class: str = Field(min_length=1)
    task_context: str = Field(min_length=1)
    memory_keys: list[str] = Field(default_factory=list)
    parent_agent_id: str
    human_session_id: str
    spawn_depth: int
    root_orchestrator_id: str
    vault_role_id: str
    vault_secret_id: str


class TerminateRequest(BaseModel):
    agent_id: str
    requestor_agent_id: str
    human_session_id: str
    root_orchestrator_id: str


app = FastAPI(title="beeai-runtime-stub")
agents: dict[str, dict] = {}


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/spawn")
async def spawn(body: SpawnRequest) -> dict:
    agent_id = f"agt-{uuid.uuid4().hex[:10]}"
    agents[agent_id] = {
        "agent_id": agent_id,
        "class": body.agent_class,
        "status": "active",
        "parent_agent_id": body.parent_agent_id,
        "human_session_id": body.human_session_id,
        "spawn_depth": body.spawn_depth,
        "root_orchestrator_id": body.root_orchestrator_id,
        "vault_role_id": body.vault_role_id,
    }
    return {"agent_id": agent_id, "status": "spawned"}


@app.post("/terminate")
async def terminate(body: TerminateRequest) -> dict:
    if body.agent_id not in agents:
        raise HTTPException(status_code=404, detail="Agent not found")
    agents.pop(body.agent_id, None)
    return {"agent_id": body.agent_id, "status": "terminated"}
