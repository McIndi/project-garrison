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

Run bootstrap using containerized Terraform (same network namespace as compose services):

```bash
GARRISON_TERRAFORM=true GARRISON_TERRAFORM_CONTAINER=true bash scripts/bootstrap.sh
```

Run bootstrap with local Vault TLS enabled. This generates a short-lived self-signed startup certificate, brings Vault up over HTTPS, then replaces it with a Vault PKI-issued listener certificate during bootstrap:

```bash
GARRISON_VAULT_TLS=true bash scripts/bootstrap.sh
```

This executes:

- Compose bring-up for core services.
- Vault baseline bootstrap via `scripts/vault-bootstrap.sh`.
	- Default mode: script-managed Vault API calls.
	- Terraform mode (`GARRISON_TERRAFORM=true`): `tofu/terraform init + apply` from `terraform/`.
	- Containerized Terraform mode (`GARRISON_TERRAFORM_CONTAINER=true`): runs Terraform in a container attached to the compose network (`vault` DNS path), using image `GARRISON_TERRAFORM_IMAGE`.
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

Run smoke using containerized Terraform (CI-equivalent Terraform runtime):

```bash
GARRISON_TERRAFORM=true GARRISON_TERRAFORM_CONTAINER=true bash scripts/ci-smoke.sh
```

Optional environment variables:

- `PYTHON_CMD` to select a specific Python interpreter.
- `CI_INSTALL_DEPS=true` to force dependency installation.
- `GARRISON_TERRAFORM=true` to run `tofu/terraform apply` before parity checks.
- `GARRISON_TERRAFORM_CONTAINER=true` to run Terraform in a container on the compose network.
- `GARRISON_TERRAFORM_IMAGE` to override the Terraform container image (default: `hashicorp/terraform:1.12.1`; CI uses a custom image with curl installed).
- `GARRISON_VAULT_TLS=true` to bootstrap Vault with HTTPS using a local self-signed cert and then rotate the listener cert from Vault PKI.

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

When `GARRISON_TERRAFORM_CONTAINER=true` is also set, init/apply run inside the configured Terraform container image and target Vault via compose-network DNS (`http://vault:8200`).

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
