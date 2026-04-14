# Project Garrison Operator Runbook (Phase 7)

## Purpose

This runbook provides the local bootstrap, verification, and CI-equivalent smoke sequence for Project Garrison.

## Prerequisites

- Podman with compose provider or Docker with compose.
- Python environment for tests.
- OpenTofu or Terraform for IaC provisioning/validation.

## Local Runtime Bootstrap

From repository root:

```bash
bash scripts/bootstrap.sh
```

Run bootstrap using Terraform-backed Vault provisioning:

```bash
GARRISON_TERRAFORM=true bash scripts/bootstrap.sh
```

This executes:

- Compose bring-up for core services.
- Vault baseline bootstrap via `scripts/vault-bootstrap.sh`.
	- Default mode: script-managed Vault API calls.
	- Terraform mode (`GARRISON_TERRAFORM=true`): `tofu/terraform init + apply` from `terraform/`.
- Vault readiness checks.
- Vault policy matrix checks.
- Vault dynamic secret lifecycle checks.
- Runtime sanity checks.

Terraform integration note:

- `bootstrap.sh` supports both default script mode and Terraform mode via `GARRISON_TERRAFORM=true`.
- `ci-smoke.sh` supports the same Terraform toggle for CI-equivalent parity runs.

## Single-Command Smoke Verification

Run the Phase 7 smoke command:

```bash
bash scripts/ci-smoke.sh
```

Run smoke using Terraform-backed Vault provisioning:

```bash
GARRISON_TERRAFORM=true bash scripts/ci-smoke.sh
```

Optional environment variables:

- `PYTHON_CMD` to select a specific Python interpreter.
- `CI_INSTALL_DEPS=true` to force dependency installation.
- `GARRISON_TERRAFORM=true` to run `tofu/terraform apply` before parity checks.

The smoke command validates:

- Core runtime bootstrap.
- Vault readiness and policy/deep-secret checks.
- Runtime spawn/delete and orchestration sanity flow.
- Tool-server tests.
- Open WebUI pipeline tests.

When `GARRISON_TERRAFORM=true` is set, the smoke flow additionally:

- Runs `tofu|terraform -chdir=terraform init -backend=false`.
- Runs `tofu|terraform -chdir=terraform apply -auto-approve`.
- Uses existing Vault scripts as post-apply parity validators.

## Terraform/OpenTofu Validation and Apply

Validate IaC structure:

```bash
# Terraform
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate

# Or OpenTofu
tofu -chdir=terraform init -backend=false
tofu -chdir=terraform validate
```

Apply Terraform-managed Vault baseline (manual path):

```bash
# Terraform
terraform -chdir=terraform apply -auto-approve

# Or OpenTofu
tofu -chdir=terraform apply -auto-approve
```

The root stack and module order are defined in:

- `terraform/main.tf`
- `terraform/variables.tf`
- `terraform/outputs.tf`

## Enterprise Transition Path

Phase 7 transition path:

1. Keep script and Terraform paths in parity until confidence gates are stable.
2. Promote CI smoke (`GARRISON_TERRAFORM=true`) + Terraform validate as release gates.
3. Split local runtime values from enterprise values by environment variable files.
4. Add policy/security controls for target platform (OpenShift/ROKS, enterprise identity and gateways).
