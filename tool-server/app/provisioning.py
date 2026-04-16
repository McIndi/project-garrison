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

    @staticmethod
    def _role_policies(role_name: str) -> list[str]:
        additive = {
            "orchestrator": "garrison-orchestrator",
            "rag": "garrison-rag",
            "code": "garrison-code",
            # analyst intentionally has no additive policy.
        }
        policies = ["default", "garrison-base"]
        extra = additive.get(role_name)
        if extra:
            policies.append(extra)
        return policies

    def _mongo_client(self) -> MongoClient:
        if self._mongo is None:
            self._mongo = MongoClient(settings.mongo_uri, serverSelectionTimeoutMS=3000)
        return self._mongo

    async def issue_spawn_credentials(self, agent_class: str) -> VaultSpawnCredentials:
        client_kwargs = {"timeout": 10}
        if settings.vault_verify is not True:
            client_kwargs["verify"] = settings.vault_verify
        async with httpx.AsyncClient(**client_kwargs) as client:
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
        client_kwargs = {"timeout": 10}
        if settings.vault_verify is not True:
            client_kwargs["verify"] = settings.vault_verify
        async with httpx.AsyncClient(**client_kwargs) as client:
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
