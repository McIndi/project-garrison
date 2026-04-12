"""Open WebUI pipeline stub for Garrison audit forwarding.

This is a placeholder that captures request/response metadata and can
forward it to OTel collector in future phases.
"""

from __future__ import annotations

import hashlib
import json
import os
from datetime import UTC, datetime
from uuid import uuid4
from typing import Any


class Pipeline:
    def __init__(self) -> None:
        self.name = "garrison-audit"
        self.payload_mode = os.getenv("GARRISON_AUDIT_PAYLOAD_MODE", "full")

    def _payload_repr(self, payload: dict[str, Any]) -> str:
        raw = json.dumps(payload, default=str).encode("utf-8")
        if self.payload_mode == "hash-only":
            return hashlib.sha256(raw).hexdigest()
        if self.payload_mode == "redacted":
            text = raw.decode("utf-8", errors="replace")
            for secret_key in ("authorization", "token", "password", "secret", "api_key"):
                text = text.replace(secret_key, f"{secret_key}_redacted")
            return text
        return raw.decode("utf-8", errors="replace")

    def _emit_event(self, stage: str, body: dict[str, Any], user: dict[str, Any] | None = None) -> None:
        meta = body.get("metadata", {}) if isinstance(body, dict) else {}
        event = {
            "trace_id": meta.get("trace_id") or str(uuid4()),
            "agent_id": meta.get("agent_id", "human-ui"),
            "agent_class": meta.get("agent_class", "human"),
            "human_session_id": (user or {}).get("session_id") or meta.get("human_session_id") or "system:bootstrap",
            "model_provider": meta.get("model_provider", "open-webui"),
            "model_name": meta.get("model", "unknown"),
            "token_counts": meta.get("token_counts", {}),
            "tool_name": f"open-webui:{stage}",
            "status": "ok",
            "timestamp": datetime.now(UTC).isoformat(),
            "payload_mode": self.payload_mode,
            "payload": self._payload_repr(body if isinstance(body, dict) else {"raw": str(body)}),
        }
        print(json.dumps(event, default=str))

    async def inlet(self, body: dict[str, Any], user: dict[str, Any] | None = None) -> dict[str, Any]:
        body.setdefault("metadata", {})
        body["metadata"]["human_session_id"] = (
            (user or {}).get("session_id") or body["metadata"].get("human_session_id") or "system:bootstrap"
        )
        body["metadata"].setdefault("trace_id", str(uuid4()))
        self._emit_event("inlet", body, user)
        return body

    async def outlet(self, body: dict[str, Any], user: dict[str, Any] | None = None) -> dict[str, Any]:
        self._emit_event("outlet", body, user)
        return body
