"""Open WebUI pipeline for Garrison audit and telemetry forwarding."""

from __future__ import annotations

import hashlib
import json
import os
import time
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
        self.orchestrate_bearer_token = os.getenv("GARRISON_ORCHESTRATE_BEARER_TOKEN", "")
        self.orchestrate_preferred_class = os.getenv("GARRISON_ORCHESTRATE_DEFAULT_CLASS", "rag")
        self.orchestrate_required_roles = self._csv_env("GARRISON_ORCHESTRATE_REQUIRED_ROLES")
        self.orchestrate_required_groups = self._csv_env("GARRISON_ORCHESTRATE_REQUIRED_GROUPS")
        self.orchestrate_authz_mode = os.getenv("GARRISON_ORCHESTRATE_AUTHZ_MODE", "any").lower().strip()
        self.orchestrate_require_user_claims = os.getenv("GARRISON_ORCHESTRATE_REQUIRE_USER_CLAIMS", "true").lower() == "true"
        self.oidc_required_issuer = os.getenv("GARRISON_OIDC_REQUIRED_ISSUER", "").strip()
        self.oidc_required_audience = os.getenv("GARRISON_OIDC_REQUIRED_AUDIENCE", "").strip()
        self.oidc_require_exp = os.getenv("GARRISON_OIDC_REQUIRE_EXP", "true").lower() == "true"
        self.oidc_clock_skew_seconds = int(os.getenv("GARRISON_OIDC_CLOCK_SKEW_SECONDS", "60"))
        self.otel_enabled = os.getenv("GARRISON_OTEL_ENABLED", "true").lower() == "true"
        self.otel_logs_endpoint = os.getenv("GARRISON_OTEL_LOGS_ENDPOINT", "http://otel-collector:4318/v1/logs")
        self.otel_timeout_seconds = float(os.getenv("GARRISON_OTEL_TIMEOUT_SECONDS", "2"))

    @staticmethod
    def _csv_env(name: str) -> set[str]:
        raw = os.getenv(name, "")
        if not raw:
            return set()
        return {item.strip() for item in raw.split(",") if item.strip()}

    @staticmethod
    def _as_claim_set(value: Any) -> set[str]:
        if isinstance(value, str):
            return {value.strip()} if value.strip() else set()
        if isinstance(value, list):
            return {str(item).strip() for item in value if str(item).strip()}
        return set()

    def _extract_user_claims(self, user: dict[str, Any] | None) -> dict[str, Any]:
        user_obj = user or {}
        roles = set()
        groups = set()
        for role_key in ("roles", "role", "realm_roles"):
            roles |= self._as_claim_set(user_obj.get(role_key))
        for group_key in ("groups", "group"):
            groups |= self._as_claim_set(user_obj.get(group_key))

        return {
            "sub": user_obj.get("sub") or user_obj.get("user_id") or user_obj.get("id"),
            "iss": user_obj.get("iss") or user_obj.get("issuer"),
            "aud": sorted(self._as_claim_set(user_obj.get("aud") or user_obj.get("audience"))),
            "exp": user_obj.get("exp"),
            "roles": sorted(roles),
            "groups": sorted(groups),
        }

    def _authorize_orchestration(self, user: dict[str, Any] | None) -> dict[str, Any]:
        claims = self._extract_user_claims(user)

        if self.orchestrate_require_user_claims and (not claims["sub"] or not claims["iss"]):
            raise PermissionError("Missing required user identity claims (sub/iss)")

        if self.oidc_required_issuer and claims["iss"] != self.oidc_required_issuer:
            raise PermissionError("User token issuer is not authorized")

        if self.oidc_required_audience and self.oidc_required_audience not in set(claims["aud"]):
            raise PermissionError("User token audience is not authorized")

        if self.oidc_require_exp:
            if claims["exp"] is None:
                raise PermissionError("User token is missing exp claim")
            try:
                exp_value = int(claims["exp"])
            except (TypeError, ValueError) as exc:
                raise PermissionError("User token exp claim is invalid") from exc
            now = int(time.time())
            if exp_value + self.oidc_clock_skew_seconds < now:
                raise PermissionError("User token is expired")

        role_match = not self.orchestrate_required_roles or bool(set(claims["roles"]) & self.orchestrate_required_roles)
        group_match = not self.orchestrate_required_groups or bool(set(claims["groups"]) & self.orchestrate_required_groups)

        if self.orchestrate_authz_mode not in {"any", "all"}:
            raise PermissionError("Invalid orchestration authz mode configured")

        if self.orchestrate_authz_mode == "all":
            authorized = role_match and group_match
        else:
            authorized = role_match or group_match

        if not authorized:
            raise PermissionError("User is not authorized for orchestration")

        return claims

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

    async def _emit_otel_log(self, stage: str, body: dict[str, Any], user: dict[str, Any] | None = None) -> None:
        if not self.otel_enabled:
            return

        meta = body.get("metadata", {}) if isinstance(body, dict) else {}
        ts = datetime.now(UTC)
        event_body = {
            "trace_id": meta.get("trace_id") or str(uuid4()),
            "stage": stage,
            "human_session_id": (user or {}).get("session_id") or meta.get("human_session_id") or "system:bootstrap",
            "model": meta.get("model", "unknown"),
            "pipeline": self.name,
        }

        payload = {
            "resourceLogs": [
                {
                    "resource": {
                        "attributes": [
                            {"key": "service.name", "value": {"stringValue": "garrison-open-webui-pipeline"}},
                            {"key": "service.namespace", "value": {"stringValue": "project-garrison"}},
                        ]
                    },
                    "scopeLogs": [
                        {
                            "scope": {"name": "garrison.open-webui.audit"},
                            "logRecords": [
                                {
                                    "timeUnixNano": str(int(ts.timestamp() * 1_000_000_000)),
                                    "severityText": "INFO",
                                    "body": {"stringValue": json.dumps(event_body, default=str)},
                                    "attributes": [
                                        {"key": "stage", "value": {"stringValue": stage}},
                                        {"key": "trace_id", "value": {"stringValue": event_body["trace_id"]}},
                                        {"key": "pipeline", "value": {"stringValue": self.name}},
                                    ],
                                }
                            ],
                        }
                    ],
                }
            ]
        }

        async with httpx.AsyncClient(timeout=self.otel_timeout_seconds) as client:
            resp = await client.post(self.otel_logs_endpoint, json=payload)
            resp.raise_for_status()

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

    async def _maybe_orchestrate(self, body: dict[str, Any], human_session_id: str, user: dict[str, Any] | None = None) -> dict[str, Any] | None:
        if not self.orchestrate_enabled:
            return None

        if not self.orchestrate_bearer_token:
            raise RuntimeError("Missing GARRISON_ORCHESTRATE_BEARER_TOKEN")

        self._authorize_orchestration(user)

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
            orchestration = await self._maybe_orchestrate(body, human_session_id, user)
            if orchestration is not None:
                body["metadata"]["garrison_orchestration"] = orchestration
        except Exception as exc:  # noqa: BLE001
            body["metadata"]["garrison_orchestration_error"] = str(exc)

        claims = self._extract_user_claims(user)
        body["metadata"]["user_sub"] = claims["sub"] or ""
        body["metadata"]["user_issuer"] = claims["iss"] or ""
        body["metadata"]["user_audience"] = claims["aud"]
        body["metadata"]["user_roles"] = claims["roles"]
        body["metadata"]["user_groups"] = claims["groups"]

        try:
            await self._emit_otel_log("inlet", body, user)
        except Exception:  # noqa: BLE001
            # Telemetry forwarding is best-effort and should not block UI processing.
            pass

        self._emit_event("inlet", body, user)
        return body

    async def outlet(self, body: dict[str, Any], user: dict[str, Any] | None = None) -> dict[str, Any]:
        try:
            await self._emit_otel_log("outlet", body, user)
        except Exception:  # noqa: BLE001
            # Telemetry forwarding is best-effort and should not block UI processing.
            pass

        self._emit_event("outlet", body, user)
        return body
