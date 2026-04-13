# Operations

## Bootstrap

Run full local stack bootstrap:

```bash
bash scripts/bootstrap.sh
```

Bootstrap includes:

- Compose up and image build.
- Vault baseline config.
- Keycloak realm/client/role/group baseline config.
- Runtime audit ingest token generation and injection for Fluent Bit/tool-server.
- Open WebUI scoped orchestrate token issuance from Vault and Open WebUI startup with injected token.
- Strict token metadata contract enforcement in tool-server (`agent_id`, `agent_class`).
- Open WebUI pipeline claim-based orchestration authorization (required roles/groups and `sub`/`iss` claims).
- Vault readiness checks.
- Vault policy matrix checks.
- Vault dynamic secret lifecycle checks.
- Nginx proxy readiness checks.
- Audit evidence checks (Vault + Nginx logs via Fluent Bit into MongoDB).
- Runtime sanity checks.

Run only Keycloak bootstrap + checks:

```bash
bash scripts/keycloak-bootstrap.sh
bash scripts/keycloak-readiness.sh
```

Run only audit evidence checks:

```bash
bash scripts/audit-pipeline-check.sh
```

## Smoke Flow

Run CI-equivalent command:

```bash
bash scripts/ci-smoke.sh
```

Issue only the Open WebUI orchestrate service token:

```bash
bash scripts/issue-openwebui-token.sh
```

Issue only the runtime audit ingest token:

```bash
bash scripts/issue-audit-ingest-token.sh
```

Optional environment knobs:

- PYTHON_CMD for explicit interpreter.
- CI_INSTALL_DEPS=true to force dependency install.
- KEYCLOAK_BASE_URL (default: `127.0.0.1:8081`)
- KEYCLOAK_ADMIN_USER / KEYCLOAK_ADMIN_PASSWORD
- KEYCLOAK_REALM (default: garrison)
- KEYCLOAK_OPENWEBUI_CLIENT_ID / KEYCLOAK_OPENWEBUI_CLIENT_SECRET
- KEYCLOAK_ORCHESTRATOR_ROLE / KEYCLOAK_ORCHESTRATOR_GROUP

Phase C orchestration authz knobs (Open WebUI pipeline):

- GARRISON_ORCHESTRATE_REQUIRED_ROLES (comma-separated)
- GARRISON_ORCHESTRATE_REQUIRED_GROUPS (comma-separated)
- GARRISON_ORCHESTRATE_AUTHZ_MODE (`any|all`)
- GARRISON_ORCHESTRATE_REQUIRE_USER_CLAIMS (`true|false`)
- GARRISON_OIDC_REQUIRED_ISSUER
- GARRISON_OIDC_REQUIRED_AUDIENCE
- GARRISON_OIDC_REQUIRE_EXP (`true|false`)
- GARRISON_OIDC_CLOCK_SKEW_SECONDS

## Test Commands

Tool-server tests:

```bash
cd tool-server
python -m pytest -q tests
```

Open WebUI pipeline tests:

```bash
cd open-webui/pipelines
python -m pytest -q test_garrison_audit.py
```

## Troubleshooting

- If Open WebUI is not ready after bootstrap, inspect compose status and logs.
- If Vault checks fail, re-run vault-bootstrap.sh before readiness scripts.
- If audit evidence checks fail, inspect fluent-bit and tool-server logs and confirm MongoDB is reachable at 127.0.0.1:27017.
- If token lookup failures occur, verify Vault is reachable and token is valid.
