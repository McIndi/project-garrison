# Operations

## Bootstrap

Run full local stack bootstrap:

```bash
bash scripts/bootstrap.sh
```

Bootstrap includes:

- Compose up and image build.
- Vault baseline config.
- Runtime audit ingest token generation and injection for Fluent Bit/tool-server.
- Open WebUI scoped orchestrate token issuance from Vault and Open WebUI startup with injected token.
- Strict token metadata contract enforcement in tool-server (`agent_id`, `agent_class`).
- Vault readiness checks.
- Vault policy matrix checks.
- Vault dynamic secret lifecycle checks.
- Nginx proxy readiness checks.
- Audit evidence checks (Vault + Nginx logs via Fluent Bit into MongoDB).
- Runtime sanity checks.

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
