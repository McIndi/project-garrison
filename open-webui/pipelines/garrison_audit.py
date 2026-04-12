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

import httpx


class Pipeline:
    def __init__(self) -> None:
        self.name = "garrison-audit"
        self.payload_mode = os.getenv("GARRISON_AUDIT_PAYLOAD_MODE", "full")
        self.orchestrate_enabled = os.getenv("GARRISON_ORCHESTRATE_ENABLED", "true").lower() == "true"
        self.orchestrate_url = os.getenv("GARRISON_ORCHESTRATE_URL", "http://tool-server:8080/orchestrate")
        self.orchestrate_timeout_seconds = float(os.getenv("GARRISON_ORCHESTRATE_TIMEOUT_SECONDS", "8"))
        self.orchestrate_agent_id = os.getenv("GARRISON_ORCHESTRATE_AGENT_ID", "agent-root")
        self.orchestrate_agent_class = os.getenv("GARRISON_ORCHESTRATE_AGENT_CLASS", "orchestrator")
        self.orchestrate_root_id = os.getenv("GARRISON_ORCHESTRATE_ROOT_ID", self.orchestrate_agent_id)
        self.orchestrate_bearer_token = os.getenv("GARRISON_ORCHESTRATE_BEARER_TOKEN", "root")
        self.orchestrate_preferred_class = os.getenv("GARRISON_ORCHESTRATE_DEFAULT_CLASS", "rag")

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

    @staticmethod
    def _extract_request_text(body: dict[str, Any]) -> str:
        messages = body.get("messages", []) if isinstance(body, dict) else []
        for message in reversed(messages):
            if not isinstance(message, dict):
                continue
            if message.get("role") != "user":
                continue
            content = message.get("content", "")
            if isinstance(content, str) and content.strip():
                return content.strip()
            if isinstance(content, list):
                chunks: list[str] = []
                for item in content:
                    if isinstance(item, dict) and item.get("type") == "text":
                        text = str(item.get("text", "")).strip()
                        if text:
                            chunks.append(text)
                if chunks:
                    return "\n".join(chunks)

        prompt = body.get("prompt") if isinstance(body, dict) else None
        if isinstance(prompt, str) and prompt.strip():
            return prompt.strip()

        return ""

    def _orchestrate_headers(self, human_session_id: str) -> dict[str, str]:
        return {
            "Authorization": f"Bearer {self.orchestrate_bearer_token}",
            "x-agent-id": self.orchestrate_agent_id,
            "x-agent-class": self.orchestrate_agent_class,
            "x-human-session-id": human_session_id,
            "x-spawn-depth": "0",
            "x-root-orchestrator-id": self.orchestrate_root_id,
            "Content-Type": "application/json",
        }

    async def _maybe_orchestrate(self, body: dict[str, Any], human_session_id: str) -> dict[str, Any] | None:
        if not self.orchestrate_enabled:
            return None

        request_text = self._extract_request_text(body)
        if not request_text:
            return None

        payload = {
            "request_text": request_text,
            "human_session_id": human_session_id,
            "preferred_agent_class": self.orchestrate_preferred_class,
        }

        async with httpx.AsyncClient(timeout=self.orchestrate_timeout_seconds) as client:
            resp = await client.post(
                self.orchestrate_url,
                headers=self._orchestrate_headers(human_session_id),
                json=payload,
            )
            resp.raise_for_status()
            return resp.json()

    async def inlet(self, body: dict[str, Any], user: dict[str, Any] | None = None) -> dict[str, Any]:
        body.setdefault("metadata", {})
        human_session_id = (
            (user or {}).get("session_id") or body["metadata"].get("human_session_id") or "system:bootstrap"
        )
        body["metadata"]["human_session_id"] = human_session_id
        body["metadata"].setdefault("trace_id", str(uuid4()))

        try:
            orchestration = await self._maybe_orchestrate(body, human_session_id)
            if orchestration is not None:
                body["metadata"]["garrison_orchestration"] = orchestration
        except Exception as exc:  # noqa: BLE001
            body["metadata"]["garrison_orchestration_error"] = str(exc)

        self._emit_event("inlet", body, user)
        return body

    async def outlet(self, body: dict[str, Any], user: dict[str, Any] | None = None) -> dict[str, Any]:
        self._emit_event("outlet", body, user)
        return body
