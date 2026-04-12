"""Open WebUI pipeline stub for Garrison audit forwarding.

This is a placeholder that captures request/response metadata and can
forward it to OTel collector in future phases.
"""

from __future__ import annotations

from typing import Any


class Pipeline:
    def __init__(self) -> None:
        self.name = "garrison-audit"

    async def inlet(self, body: dict[str, Any], user: dict[str, Any] | None = None) -> dict[str, Any]:
        body.setdefault("metadata", {})
        body["metadata"]["human_session_id"] = (
            (user or {}).get("session_id") or body["metadata"].get("human_session_id") or "system:bootstrap"
        )
        return body

    async def outlet(self, body: dict[str, Any], user: dict[str, Any] | None = None) -> dict[str, Any]:
        return body
