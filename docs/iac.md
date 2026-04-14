# IaC and Phase 7

## Execution Order

The Terraform/OpenTofu stack mirrors spec module order and is wired in `terraform/main.tf`:

1. infra
2. vault-core
3. vault-pki
4. vault-secrets
5. vault-transit
6. vault-policy
7. agent-role
8. agent-skill

## Current IaC Scope

Provider-backed resources are implemented across all 8 modules.

- `infra`: Vault pre-flight gate (`null_resource.vault_health`) with status-aware health checks and exponential backoff.
- `vault-core`: Audit devices + AppRole auth backend.
	- Default root input enables file audit only.
	- Syslog audit is opt-in for environments with a working syslog sink.
- `vault-pki`: Root/intermediate PKI mounts, cert chain, role provisioning.
- `vault-secrets`: Database engine mounts/connections and dynamic roles.
- `vault-transit`: Transit mount and keyring.
	- Convergent keys also enable derivation (`derived = true`) to satisfy Vault API requirements.
- `vault-policy`: Template-backed policy rendering and provisioning.
- `agent-role`: AppRole roles with one-time secret-id behavior.
- `agent-skill`: Local skill document rendering + optional Gitea publish via `null_resource` and REST calls.

## Runtime Modes

- Script-managed Vault bootstrap (default):

```bash
bash scripts/bootstrap.sh
```

- Terraform-backed Vault bootstrap:

```bash
GARRISON_TERRAFORM=true bash scripts/bootstrap.sh
```

- Containerized Terraform runtime (recommended in CI):

```bash
GARRISON_TERRAFORM=true GARRISON_TERRAFORM_CONTAINER=true bash scripts/bootstrap.sh
```

The containerized path supports overriding the image with `GARRISON_TERRAFORM_IMAGE`.

## CI Notes

The Phase 7 smoke workflow builds and uses a dedicated Terraform runner image that includes required runtime dependencies (notably `curl`) for local-exec health checks.

## Validation Commands

```bash
# Terraform
terraform fmt -check -recursive terraform modules
terraform -chdir=terraform init -backend=false
terraform -chdir=terraform validate

# OpenTofu
tofu fmt -check -recursive terraform modules
tofu -chdir=terraform init -backend=false
tofu -chdir=terraform validate
```
