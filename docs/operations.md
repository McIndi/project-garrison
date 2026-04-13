# Operations

## Bootstrap

Run full local stack bootstrap:

```bash
bash scripts/bootstrap.sh
```

Bootstrap includes:

- Compose up and image build.
- Vault baseline config.
- Vault readiness checks.
- Vault policy matrix checks.
- Vault dynamic secret lifecycle checks.
- Runtime sanity checks.

## Smoke Flow

Run CI-equivalent command:

```bash
bash scripts/ci-smoke.sh
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
- If token lookup failures occur, verify Vault is reachable and token is valid.
