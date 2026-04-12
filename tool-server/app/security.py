from dataclasses import dataclass

import httpx
from fastapi import Header, HTTPException

from .config import settings


@dataclass
class AuthContext:
    token: str
    agent_id: str
    agent_class: str
    human_session_id: str
    spawn_depth: int
    root_orchestrator_id: str


async def _lookup_vault_token(token: str) -> dict:
    url = f"{settings.vault_addr}/v1/auth/token/lookup-self"
    async with httpx.AsyncClient(timeout=5) as client:
        resp = await client.get(url, headers={"X-Vault-Token": token})
    if resp.status_code != 200:
        raise HTTPException(status_code=401, detail="Vault token lookup failed")
    payload = resp.json()
    if not payload.get("auth") and not payload.get("data"):
        raise HTTPException(status_code=401, detail="Invalid vault token payload")
    return payload


async def require_auth_context(
    authorization: str | None = Header(default=None),
    x_agent_id: str | None = Header(default=None),
    x_agent_class: str | None = Header(default=None),
    x_human_session_id: str | None = Header(default=None),
    x_spawn_depth: str | None = Header(default="0"),
    x_root_orchestrator_id: str | None = Header(default=None),
) -> AuthContext:
    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(status_code=401, detail="Missing bearer token")
    token = authorization.replace("Bearer ", "", 1).strip()
    if not token:
        raise HTTPException(status_code=401, detail="Empty bearer token")

    if settings.require_token_lookup:
        await _lookup_vault_token(token)

    if not x_agent_id or not x_agent_class:
        raise HTTPException(status_code=400, detail="Missing x-agent-id or x-agent-class")

    if not x_human_session_id:
        raise HTTPException(status_code=400, detail="Missing x-human-session-id")

    try:
        spawn_depth = int(x_spawn_depth or "0")
    except ValueError as exc:
        raise HTTPException(status_code=400, detail="Invalid x-spawn-depth") from exc

    if spawn_depth == 0:
        root_orchestrator_id = x_root_orchestrator_id or x_agent_id
    else:
        if not x_root_orchestrator_id:
            raise HTTPException(status_code=400, detail="Missing x-root-orchestrator-id for nested spawn")
        root_orchestrator_id = x_root_orchestrator_id

    return AuthContext(
        token=token,
        agent_id=x_agent_id,
        agent_class=x_agent_class,
        human_session_id=x_human_session_id,
        spawn_depth=spawn_depth,
        root_orchestrator_id=root_orchestrator_id,
    )
