# Authentication and Authorization Hardening Plan

## Scope

This audit covers:

- Open WebUI user authentication and session trust.
- Open WebUI -> tool-server service authentication.
- tool-server request authentication and authorization.
- Runtime secret/token handling and fallback behavior.
- Exposure and trust boundaries that impact authn/authz guarantees.

## Current State Audit

### High-risk gaps

1. Open WebUI auth is disabled in runtime config.

- Evidence: `WEBUI_AUTH: "False"` in compose.
- Impact: Any party with network access to Open WebUI can initiate privileged orchestration operations.

1. Open WebUI pipeline uses a static bearer token set to `root`.

- Evidence: `GARRISON_ORCHESTRATE_BEARER_TOKEN: root` and default `orchestrate_bearer_token` fallback in pipeline.
- Impact: A single long-lived root token is a high-value credential with broad blast radius.

1. tool-server identity-binding fallbacks are permissive in compose.

- Evidence: `TOOL_SERVER_ALLOW_HEADER_IDENTITY_FALLBACK: "true"` and `TOOL_SERVER_ALLOW_ROOT_TOKEN_FALLBACK: "true"`.
- Impact: Header-based identity can be accepted when token claims are missing; root token bypass weakens strict identity binding.

1. tool-server is host-exposed on port 8080 while accepting bearer auth from local scripts and Open WebUI.

- Evidence: `ports: - "8080:8080"` in compose.
- Impact: Any host-side caller can attempt direct API access against runtime endpoints.

### Medium-risk gaps

1. Keycloak is deployed but not integrated into Open WebUI auth flow.

- Evidence: Keycloak service exists; Open WebUI auth remains disabled.
- Impact: Human identity is not federated; session trust is weak and not policy-driven.

1. Internal ingest token is static and shared in compose/fluent-bit config.

- Evidence: `TOOL_SERVER_AUDIT_INGEST_TOKEN: local-audit-ingest-token` and fixed Fluent Bit header.
- Impact: Token reuse and static secret handling increase replay/abuse risk if endpoint is reachable.

1. BeeAI runtime control API has no endpoint auth (stub), relying only on network placement.

- Evidence: `/spawn` and `/terminate` have no auth checks in stub service.
- Impact: On compromised network segment, runtime control plane is easier to abuse.

### Lower-risk / contextual items

1. Development defaults use known admin credentials for Keycloak and Vault dev root token.

- Impact: acceptable for local dev bootstrap, but must be blocked in shared/non-local environments.

## Vault and Keycloak Coverage Check (Against SPEC)

This section maps current plan coverage to SPEC-intended use.

### Vault intended responsibilities and plan coverage

Covered in this plan:

- Agent/service auth via AppRole and scoped tokens.
- Strict token lookup and identity claim enforcement at tool-server.
- Removal of root/static runtime token usage.

Not yet explicit enough (added below in phases):

- Enforce token metadata stamping (`agent_id`, `agent_class`) at issuance and validate in runtime checks.
- Use Vault dynamic credentials for data-plane access by services (remove static Mongo/Valkey root credentials from runtime paths).
- Register and verify both Vault audit devices expected by SPEC (`file` and `syslog`) in secure profile (runtime default remains file audit; syslog is opt-in).
- Add Vault PKI-based service-to-service mTLS path for secure profile (tool-server <-> BeeAI runtime first).

### Keycloak intended responsibilities and plan coverage

Covered in this plan:

- Open WebUI OIDC integration.
- Role/group authorization to gate orchestration.

Not yet explicit enough (added below in phases):

- Enforce issuer/audience/expiry validation for Keycloak tokens at Open WebUI boundary.
- Define deterministic claim mapping (subject, email, groups/roles) into orchestration metadata.
- Configure session, refresh-token, and client secret rotation policy for secure profile.
- Remove default admin credentials from secure profile and bootstrap from generated/admin-secret flow.

## Authn/Authz Target State

1. Human identity: Open WebUI authentication enabled and federated via Keycloak OIDC.
2. Service identity: Open WebUI pipeline uses a dedicated non-root Vault-issued token scoped to `/orchestrate` path semantics.
3. Runtime identity enforcement: tool-server requires Vault lookup and strict token claims with no header/root fallback.
4. Boundary hardening: tool-server non-public by default; only explicit ingress path can reach it.
5. Token hygiene: remove hard-coded root/static secrets from compose defaults and scripts for normal runtime paths.
6. Continuous verification: CI and local checks fail on auth regressions.

## Implementation Plan (Actionable)

## Phase A: Immediate Guardrails (1-2 days)

1. Enable Open WebUI auth and remove anonymous access.

- Change compose to `WEBUI_AUTH: "True"`.
- Add bootstrap check that fails if WebUI auth is off in non-dev profile.

1. Tighten tool-server identity fallback behavior.

- Set in compose:
  - `TOOL_SERVER_ALLOW_HEADER_IDENTITY_FALLBACK: "false"`
  - `TOOL_SERVER_ALLOW_ROOT_TOKEN_FALLBACK: "false"`
- Keep `TOOL_SERVER_REQUIRE_TOKEN_LOOKUP: "true"`.

1. Reduce direct attack surface.

- Remove host port publish for tool-server in secure profile (keep optional local-dev override).
- Route Open WebUI -> tool-server over internal network only.

1. Add regression tests.

- Add tests that enforce strict mismatch/fallback rejection under production config defaults.

Exit criteria:

- Anonymous Open WebUI access blocked.
- Requests with missing token identity claims are denied.
- Root-token fallback path is disabled by default.

## Phase B: Service Credential Hardening (2-3 days)

1. Replace Open WebUI `root` bearer with dedicated orchestrator service identity.

- Create Vault policy for orchestrate bridge calls only.
- Issue token with short TTL and renewable path via AppRole or token role.
- Inject token at startup from Vault (or bootstrap secret handoff), not static compose literal.

1. Bind service token claims.

- Ensure token metadata includes stable `agent_id` and `agent_class=orchestrator`.
- Ensure tool-server claim checks pass without fallback flags.

1. Rotate ingest token handling.

- Replace static ingest token literal with generated secret per bootstrap.
- Pass token to Fluent Bit and tool-server via runtime secret/env injection.

1. Enforce Vault token metadata contract.

- Ensure AppRole/token issuance includes immutable metadata fields: `agent_id`, `agent_class`, `issued_for`.
- Make strict claim checks fail closed if metadata is absent or mismatched.

1. Replace static service datastore credentials.

- Move tool-server runtime access for MongoDB/Valkey to Vault dynamic credentials path.
- Keep bootstrap-only admin credentials isolated from steady-state runtime services.

Exit criteria:

- No root token in Open WebUI orchestrate path.
- Orchestrate requests succeed only with dedicated scoped service token.
- Ingest token rotation is automated.

## Phase C: OIDC Integration and User-to-Action Traceability (3-5 days)

1. Integrate Open WebUI with Keycloak OIDC.

- Configure realm/client for Open WebUI.
- Enable login flow and map user claims.
- Local bootstrap provisions deterministic Keycloak realm/client/role/group baseline via scripts.

1. Persist user identity through orchestration metadata.

- Include immutable user subject (`sub`) and issuer in orchestration metadata.
- Carry into tool-server audit events and handoff records.

1. Add authorization mapping policy.

- Define who can trigger orchestration (role/group-based).
- Reject orchestration for unauthorised human roles before calling tool-server.

1. Harden OIDC token validation and session controls.

- Validate issuer, audience, signature, expiry, and nonce/state semantics.
- Define secure profile session timeout, refresh token TTL, and re-auth requirements.
- Add client secret rotation runbook for Open WebUI OIDC client.

Exit criteria:

- Open WebUI authenticates users through Keycloak.
- Audit chain links human principal -> orchestration call -> spawned work.
- Non-authorized users cannot initiate orchestration.

## Phase D: Control Plane Hardening and Profiles (2-4 days)

1. Add runtime auth to BeeAI control API.

- Require shared service token or mTLS for `/spawn` and `/terminate`.

1. Introduce environment profiles.

- `dev`: current convenience settings with clear warnings.
- `secure`: strict auth defaults, no public tool-server port, no root fallbacks.

1. Gate insecure defaults in CI.

- Fail if secure profile contains root/static demo credentials.

1. Add Vault audit + PKI hardening gates.

- Verify both Vault audit devices (`file` and `syslog`) are configured in secure profile.
- Add phased mTLS rollout using Vault PKI for service-to-service control paths.

Exit criteria:

- Control plane endpoints require authentication.
- Secure profile is default for CI.

## Required Test and Validation Additions

1. Open WebUI auth enabled check in bootstrap/smoke (secure profile).
2. Integration test: unauthenticated Open WebUI request denied.
3. Integration test: Open WebUI authenticated user can orchestrate only with authorized role.
4. tool-server integration test: requests fail when token claims missing and fallback disabled.
5. Negative test: root token cannot bypass identity binding when fallback disabled.
6. Network test: tool-server not reachable from host in secure profile.
7. Vault token metadata contract test: token missing `agent_id`/`agent_class` is rejected.
8. Vault dynamic credential test: runtime service credentials rotate and expire as expected.
9. Vault audit device test: both `file` and `syslog` devices enabled in secure profile.
10. Keycloak OIDC validation test: bad issuer/audience/expired token rejected.
11. Keycloak RBAC test: unauthorized human role cannot invoke orchestration.

## Recommended Execution Order

1. Phase A (fast risk reduction).
2. Phase B (remove root/static service credentials).
3. Phase C (human identity federation + authz mapping).
4. Phase D (control plane hardening + profile enforcement).

## Ownership and Deliverables

- `compose.yaml`: secure defaults and profile split.
- `open-webui/pipelines/garrison_audit.py`: no static root token dependency; identity propagation fields.
- `tool-server/app/config.py` and `tool-server/app/security.py`: strict claim enforcement defaults.
- `scripts/*`: bootstrap/smoke auth gates.
- `tool-server/tests/*` and `open-webui/pipelines/test_*`: auth regression coverage.
- `docs/*`: auth architecture and operational runbook updates.
