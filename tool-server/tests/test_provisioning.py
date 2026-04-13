import asyncio

from app.provisioning import ProvisioningService


def test_role_policies_orchestrator_has_additive_policy() -> None:
    policies = ProvisioningService._role_policies("orchestrator")
    assert policies == ["default", "garrison-base", "garrison-orchestrator"]


def test_role_policies_analyst_is_base_only() -> None:
    policies = ProvisioningService._role_policies("analyst")
    assert policies == ["default", "garrison-base"]


def test_role_policies_unknown_defaults_to_base() -> None:
    policies = ProvisioningService._role_policies("custom")
    assert policies == ["default", "garrison-base"]


def test_issue_spawn_credentials_uses_existing_approle_only(monkeypatch) -> None:
    calls: list[dict] = []

    class DummyResponse:
        def __init__(self, payload):
            self._payload = payload

        def raise_for_status(self) -> None:
            return None

        def json(self):
            return self._payload

    class DummyClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def get(self, url, headers):
            calls.append({"method": "GET", "url": url, "headers": headers})
            return DummyResponse({"data": {"role_id": "role-rag-1"}})

        async def post(self, url, headers=None, json=None):
            calls.append({"method": "POST", "url": url, "headers": headers, "json": json})
            if url.endswith("/secret-id"):
                return DummyResponse({"data": {"secret_id": "sec-rag-1"}})
            if url.endswith("/login"):
                return DummyResponse({"auth": {"accessor": "acc-rag-1"}})
            raise AssertionError(f"Unexpected Vault call: {url}")

    monkeypatch.setattr("app.provisioning.httpx.AsyncClient", lambda timeout: DummyClient())

    svc = ProvisioningService()
    creds = asyncio.run(svc.issue_spawn_credentials("rag"))

    assert creds.role_id == "role-rag-1"
    assert creds.secret_id == "sec-rag-1"
    assert creds.token_accessor == "acc-rag-1"

    urls = [call["url"] for call in calls]
    assert any(url.endswith("/v1/auth/approle/role/rag/role-id") for url in urls)
    assert any(url.endswith("/v1/auth/approle/role/rag/secret-id") for url in urls)
    assert any(url.endswith("/v1/auth/approle/login") for url in urls)
    assert not any("/v1/sys/auth" in url for url in urls)
    assert not any("/v1/auth/approle/role/rag" in url and call["method"] == "POST" and not url.endswith("/secret-id") for call, url in zip(calls, urls))
