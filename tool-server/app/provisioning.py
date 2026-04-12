import uuid
from dataclasses import dataclass

import httpx
from pymongo import MongoClient
from pymongo.errors import CollectionInvalid

from .config import settings


@dataclass
class VaultSpawnCredentials:
    role_id: str
    secret_id: str
    token_accessor: str


class ProvisioningService:
    def __init__(self) -> None:
        self._mongo: MongoClient | None = None

    def _mongo_client(self) -> MongoClient:
        if self._mongo is None:
            self._mongo = MongoClient(settings.mongo_uri, serverSelectionTimeoutMS=3000)
        return self._mongo

    async def _ensure_approle_mount(self) -> None:
        async with httpx.AsyncClient(timeout=10) as client:
            auth_resp = await client.get(
                f"{settings.vault_addr}/v1/sys/auth",
                headers={"X-Vault-Token": settings.vault_token},
            )
            auth_resp.raise_for_status()
            mounts = auth_resp.json().get("data", {})
            if "approle/" in mounts:
                return
            enable_resp = await client.post(
                f"{settings.vault_addr}/v1/sys/auth/approle",
                headers={"X-Vault-Token": settings.vault_token},
                json={"type": "approle"},
            )
            enable_resp.raise_for_status()

    async def _ensure_role(self, role_name: str) -> None:
        ttl = settings.class_token_ttl.get(role_name, "1h")
        async with httpx.AsyncClient(timeout=10) as client:
            role_resp = await client.post(
                f"{settings.vault_addr}/v1/auth/approle/role/{role_name}",
                headers={"X-Vault-Token": settings.vault_token},
                json={
                    "token_ttl": ttl,
                    "token_max_ttl": ttl,
                    "secret_id_num_uses": 1,
                    "secret_id_ttl": "30m",
                    "token_no_default_policy": False,
                },
            )
            role_resp.raise_for_status()

    async def issue_spawn_credentials(self, agent_class: str) -> VaultSpawnCredentials:
        await self._ensure_approle_mount()
        await self._ensure_role(agent_class)
        async with httpx.AsyncClient(timeout=10) as client:
            role_id_resp = await client.get(
                f"{settings.vault_addr}/v1/auth/approle/role/{agent_class}/role-id",
                headers={"X-Vault-Token": settings.vault_token},
            )
            role_id_resp.raise_for_status()
            role_id = role_id_resp.json()["data"]["role_id"]

            secret_resp = await client.post(
                f"{settings.vault_addr}/v1/auth/approle/role/{agent_class}/secret-id",
                headers={"X-Vault-Token": settings.vault_token},
                json={},
            )
            secret_resp.raise_for_status()
            secret_id = secret_resp.json()["data"]["secret_id"]

            login_resp = await client.post(
                f"{settings.vault_addr}/v1/auth/approle/login",
                json={"role_id": role_id, "secret_id": secret_id},
            )
            login_resp.raise_for_status()
            token_accessor = login_resp.json()["auth"]["accessor"]

        return VaultSpawnCredentials(
            role_id=role_id,
            secret_id=secret_id,
            token_accessor=token_accessor,
        )

    async def revoke_accessor(self, accessor: str) -> None:
        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.post(
                f"{settings.vault_addr}/v1/auth/token/revoke-accessor",
                headers={"X-Vault-Token": settings.vault_token},
                json={"accessor": accessor},
            )
        resp.raise_for_status()

    def provision_agent_collections(self, agent_id: str) -> None:
        client = self._mongo_client()
        db = client[f"agent_{agent_id}"]
        for name in ("objects", "handoffs"):
            try:
                db.create_collection(name)
            except CollectionInvalid:
                pass

    @staticmethod
    def system_session_id() -> str:
        return f"system:{uuid.uuid4()}"


provisioning = ProvisioningService()
