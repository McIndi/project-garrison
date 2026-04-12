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

def test_ensure_role_posts_expected_policy_payload(monkeypatch) -> None:
    calls: list[dict] = []

    class DummyResponse:
        def raise_for_status(self) -> None:
            return None

    class DummyClient:
        async def __aenter__(self):
            return self

        async def __aexit__(self, exc_type, exc, tb):
            return False

        async def post(self, url, headers, json):
            calls.append({"url": url, "headers": headers, "json": json})
            return DummyResponse()

    monkeypatch.setattr("app.provisioning.httpx.AsyncClient", lambda timeout: DummyClient())

    svc = ProvisioningService()
    asyncio.run(svc._ensure_role("analyst"))

    assert len(calls) == 1
    payload = calls[0]["json"]
    assert payload["token_policies"] == ["default", "garrison-base"]
    assert payload["token_ttl"] == "1h"
