from dataclasses import dataclass

import httpx
from fastapi import Header, HTTPException

from .config import settings
from .provisioning import provisioning


@dataclass
class AuthContext:
    token: str
    agent_id: str
    agent_class: str
    human_session_id: str
    spawn_depth: int
    root_orchestrator_id: str


def _infer_agent_class_from_policies(policies: list[str]) -> str | None:
    if "garrison-orchestrator" in policies:
        return "orchestrator"
    if "garrison-rag" in policies:
        return "rag"
    if "garrison-code" in policies:
        return "code"
    if "garrison-base" in policies:
        return "analyst"
    return None


def _lookup_identity_claims(payload: dict) -> tuple[str | None, str | None, bool]:
    data = payload.get("data") or {}
    meta = data.get("meta") or {}
    display_name = str(data.get("display_name") or "")
    policies = [str(p) for p in data.get("policies", [])]

    claimed_agent_id = meta.get("agent_id")
    claimed_agent_class = meta.get("agent_class") or _infer_agent_class_from_policies(policies)
    is_root_token = display_name == "root" or "root" in policies
    return claimed_agent_id, claimed_agent_class, is_root_token


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

    lookup_payload: dict = {}
    if settings.require_token_lookup:
        lookup_payload = await _lookup_vault_token(token)

    if not x_agent_id or not x_agent_class:
        raise HTTPException(status_code=400, detail="Missing x-agent-id or x-agent-class")

    if settings.require_token_lookup and settings.enforce_token_identity_binding:
        claimed_agent_id, claimed_agent_class, is_root_token = _lookup_identity_claims(lookup_payload)

        can_fallback = settings.allow_header_identity_fallback
        if is_root_token and settings.allow_root_token_fallback:
            can_fallback = True

        if claimed_agent_id and claimed_agent_id != x_agent_id:
            raise HTTPException(status_code=403, detail="x-agent-id does not match token identity")
        if claimed_agent_class and claimed_agent_class != x_agent_class:
            raise HTTPException(status_code=403, detail="x-agent-class does not match token identity")

        if not claimed_agent_class and not can_fallback:
            raise HTTPException(status_code=403, detail="Token identity claims are missing for strict binding")

    human_session_id = x_human_session_id or provisioning.system_session_id()

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
        human_session_id=human_session_id,
        spawn_depth=spawn_depth,
        root_orchestrator_id=root_orchestrator_id,
    )
