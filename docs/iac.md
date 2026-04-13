# IaC and Phase 7

## Execution Order

The Terraform/OpenTofu stack mirrors spec order:

1. infra
2. vault-core
3. vault-pki
4. vault-secrets
5. vault-transit
6. vault-policy
7. agent-role
8. agent-skill

Implemented in terraform/main.tf with explicit dependency ordering.

## Current IaC Scope

- Module contracts are wired with shared input/output data flow.
- Root variables capture environment, services, Vault contracts, class definitions, and policy/transit/secrets metadata.
- Root output phase7_contract_summary exposes composed contracts.
- CI validates format and configuration initialization.

## What Is Still Ahead

- Replace contract placeholders with provider-backed resources in each module.
- Keep script-based bootstrap/checks as parity gates while migrating.
- Add environment-specific tfvars for local versus enterprise targets.

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
