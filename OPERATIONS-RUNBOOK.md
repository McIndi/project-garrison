# Project Garrison Operator Runbook (Phase 7)

## Purpose

This runbook provides the local bootstrap, verification, and CI-equivalent smoke sequence for Project Garrison.

## Prerequisites

- Podman with compose provider or Docker with compose.
- Python environment for tests.
- OpenTofu or Terraform for IaC validation.

## Local Runtime Bootstrap

From repository root:

```bash
bash scripts/bootstrap.sh
```

This executes:

- Compose bring-up for core services.
- Vault baseline bootstrap.
- Vault readiness checks.
- Vault policy matrix checks.
- Vault dynamic secret lifecycle checks.
- Runtime sanity checks.

## Single-Command Smoke Verification

Run the Phase 7 smoke command:

```bash
bash scripts/ci-smoke.sh
```

Optional environment variables:

- `PYTHON_CMD` to select a specific Python interpreter.
- `CI_INSTALL_DEPS=true` to force dependency installation.

The smoke command validates:

- Core runtime bootstrap.
- Vault readiness and policy/deep-secret checks.
- Runtime spawn/delete and orchestration sanity flow.
- Tool-server tests.
- Open WebUI pipeline tests.

## Terraform/OpenTofu Validation

Validate IaC contract structure:

```bash
# Terraform
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate

# Or OpenTofu
tofu -chdir=terraform init -backend=false
tofu -chdir=terraform validate
```

The root stack and module order are defined in:

- `terraform/main.tf`
- `terraform/variables.tf`
- `terraform/outputs.tf`

## Enterprise Transition Path (Planned)

Phase 7 transition path:

1. Replace module placeholders with provider-backed resources in module order.
2. Keep runtime script behavior as reference until equivalent IaC behavior is validated.
3. Promote CI smoke + Terraform validate as release gates.
4. Split local runtime values from enterprise values by environment variable files.
5. Add policy/security controls for target platform (OpenShift/ROKS, enterprise identity and gateways).
