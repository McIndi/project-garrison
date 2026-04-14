# Terraform Implementation Plan — Project Garrison

**Branch:** `feat/ok-lets-add-terraform-proper`
**Status:** Implemented in current branch — Phase 7 Terraform provider-backed pass

This document is the canonical reference for implementing provider-backed Terraform resources
in module order, per the grounded next-step noted in EXECUTION-PLAN.md Phase 7.

---

## Context

Terraform modules are provider-backed and validate cleanly.
All 8 modules are wired and include concrete resources for Vault provisioning.
Vault can be bootstrapped via Terraform in both:
- `GARRISON_TERRAFORM=true bash scripts/bootstrap.sh`
- `GARRISON_TERRAFORM=true bash scripts/ci-smoke.sh`

This plan replaces `vault-bootstrap.sh` configuration with Terraform-managed resources.
The existing scripts (`vault-readiness.sh`, `vault-policy-check.sh`, etc.) become
**parity validators** — they stay and run AFTER `tofu apply` to confirm correctness.

---

## Prerequisites (confirmed from EXECUTION-PLAN + OPERATIONS-RUNBOOK)

Before `terraform apply` can succeed:

1. **Compose stack is running** — `tofu apply` targets a live Vault. Compose stays the
   bring-up mechanism. Terraform is NOT responsible for starting containers.
2. **Vault is unsealed** — local dev uses Vault in dev mode. `VAULT_ADDR=http://127.0.0.1:8200`
   and `VAULT_TOKEN=root` must be set in the environment.
3. **Gitea is running** — required ONLY for the `agent-skill` module. Set
   `gitea_provisioning_enabled = false` in `terraform.tfvars` to skip until Gitea is ready.
4. **OpenTofu >= 1.6.0 installed** — confirmed in `versions.tf`.
5. **`tofu init` has been run** — installs required providers.

> **Hard constraint from SPEC:** Secret-ids are NEVER generated or stored in Terraform state.
> Only AppRole role definitions (and stable role-ids) are managed here.
> Secret-id issuance stays in `provisioning.py` and the spawn scripts.

---

## Import Commands (first-time transition from script-managed Vault)

If Vault is configured by `vault-bootstrap.sh`, import existing resources before applying to avoid conflicts. On a fresh (dev) Vault instance, skip this step.

```bash
# Auth backend
tofu -chdir=terraform import module.vault_core.vault_auth_backend.approle approle

# Audit devices
tofu -chdir=terraform import module.vault_core.vault_audit.devices[\"file\"] file
# Optional (only if syslog audit is explicitly enabled in your vars):
tofu -chdir=terraform import module.vault_core.vault_audit.devices[\"syslog\"] syslog

# Transit mount + keys
tofu -chdir=terraform import module.vault_transit.vault_mount.transit transit
tofu -chdir=terraform import module.vault_transit.vault_transit_secret_backend_key.keys[\"agent-payload\"] transit/agent-payload
tofu -chdir=terraform import module.vault_transit.vault_transit_secret_backend_key.keys[\"shared-memory\"] transit/shared-memory
tofu -chdir=terraform import module.vault_transit.vault_transit_secret_backend_key.keys[\"artifact-signing\"] transit/artifact-signing

# Policies
tofu -chdir=terraform import 'module.vault_policy.vault_policy.policies["garrison-base"]' garrison-base
tofu -chdir=terraform import 'module.vault_policy.vault_policy.policies["garrison-orchestrator"]' garrison-orchestrator
tofu -chdir=terraform import 'module.vault_policy.vault_policy.policies["garrison-rag"]' garrison-rag
tofu -chdir=terraform import 'module.vault_policy.vault_policy.policies["garrison-code"]' garrison-code
tofu -chdir=terraform import 'module.vault_policy.vault_policy.policies["garrison-tool-server"]' garrison-tool-server

# AppRole roles
tofu -chdir=terraform import 'module.agent_role.vault_approle_auth_backend_role.roles["orchestrator"]' auth/approle/role/orchestrator
tofu -chdir=terraform import 'module.agent_role.vault_approle_auth_backend_role.roles["code"]' auth/approle/role/code
tofu -chdir=terraform import 'module.agent_role.vault_approle_auth_backend_role.roles["rag"]' auth/approle/role/rag
tofu -chdir=terraform import 'module.agent_role.vault_approle_auth_backend_role.roles["analyst"]' auth/approle/role/analyst
```

---

## Phase 1 — Provider Declarations

**Files:** `terraform/versions.tf`, `terraform/providers.tf`, `terraform/terraform.tfvars.example`

Required providers (per SPEC):

| Provider | Source | Version |
|----------|--------|---------|
| vault | hashicorp/vault | ~> 4.0 |
| docker | kreuzwerker/docker | ~> 3.0 |
| local | hashicorp/local | ~> 2.0 |
| null | hashicorp/null | ~> 3.0 |

> **Note:** The `gitea/gitea` provider is not available in either the OpenTofu or Terraform
> registries. The `agent-skill` module uses `null_resource` + `local-exec` + `curl` to commit
> skill documents via the Gitea REST API instead. No external Gitea provider is required.

Provider env vars (set in shell, not in `terraform.tfvars`):

```bash
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=root
export DOCKER_HOST=unix:///run/user/$(id -u)/podman/podman.sock   # Podman
# export DOCKER_HOST=unix:///var/run/docker.sock                  # Docker
export GITEA_BASE_URL=http://localhost:3001
export GITEA_TOKEN=<your-gitea-token>
```

State backend: local (`terraform/terraform.tfstate`). State files are gitignored.
Enterprise path: migrate to encrypted remote state before production deployment.

**Validation:** `tofu init && tofu validate`

---

## Phase 2 — modules/infra — Service Health Gate

Layer 0. Uses `null` provider to verify Vault is reachable before downstream modules run.
This replaces "check it manually" with a Terraform-enforced pre-flight gate.

**Resources:** `null_resource.vault_health` — `local-exec` calling `curl /v1/sys/health`

Vault address passed as `var.vault_addr` (same as the vault_core module).

---

## Phase 3 — modules/vault-core — Audit Devices + AppRole Mount

Maps 1:1 to the first three blocks of `vault-bootstrap.sh`.

**Resources:**
- `vault_audit.devices` — `for_each` over `var.audit_devices` (default file-only; syslog opt-in)
- `vault_auth_backend.approle` — type = "approle", path = "approle"

**Parity gate:** `scripts/vault-readiness.sh` must pass after apply.

---

## Phase 4 — modules/vault-pki — Internal CA + TLS Role

**Resources (in dependency order):**
1. `vault_mount.pki_root` — Root CA mount, max_lease_ttl 10y
2. `vault_mount.pki_int` — Intermediate CA mount, max_lease_ttl 1y
3. `vault_pki_secret_backend_root_cert.root` — Generates root CA (internal, RSA-4096)
4. `vault_pki_secret_backend_config_urls.root` — Issuing + CRL URLs for root
5. `vault_pki_secret_backend_intermediate_cert_request.int` — Generates intermediate CSR
6. `vault_pki_secret_backend_root_sign_intermediate.int` — Root signs intermediate CSR
7. `vault_pki_secret_backend_intermediate_set_signed.int` — Sets signed cert on int mount
8. `vault_pki_secret_backend_config_urls.int` — Issuing + CRL URLs for intermediate
9. `vault_pki_secret_backend_role.roles` — `for_each` over `var.pki_roles` (agent-mesh)

Output adds `root_ca_serial` and `issuing_ca_path` to `pki_contract`.

---

## Phase 5 — modules/vault-secrets — Dynamic Secret Engines + Roles

Maps to the database connection and role blocks in `vault-bootstrap.sh`.

**New variables (sensitive):**
- `mongo_root_username` (default: "root")
- `mongo_root_password` (sensitive, no default)
- `valkey_password` (sensitive, no default)

**Resources:**
- `vault_mount.database` — database secret engine
- `vault_database_secret_backend_connection.mongo` — MongoDB plugin connection
- `vault_database_secret_backend_connection.valkey` — Redis plugin connection (valkey)
- `vault_database_secret_backend_role.roles` — `for_each` over `var.dynamic_secret_roles`

Connection naming convention: roles prefixed `mongo-*` map to the `mongo` connection,
`valkey-*` roles map to the `valkey` connection.

**Parity gate:** `scripts/vault-dynamic-secrets-check.sh` must pass after apply.

---

## Phase 6 — modules/vault-transit — Transit Keyring

Maps to the transit key creation in `vault-bootstrap.sh`.

**Resources:**
- `vault_mount.transit` — transit secret engine
- `vault_transit_secret_backend_key.keys` — `for_each` over `var.transit_keys`

Key properties from var.transit_keys:
- `agent-payload`: aes256-gcm96, convergent=false
- `shared-memory`: aes256-gcm96, convergent=true (deterministic for dedup)
- `artifact-signing`: ed25519, convergent=false

Implementation note: convergent keys enable derivation (`derived = true`) to satisfy Vault transit API requirements.

Note: `deletion_allowed = false` for all keys. Add `prevent_destroy` before enterprise deploy.

**Parity gate:** transit encrypt/decrypt in `scripts/sanity-check.sh` must pass after apply.

---

## Phase 7 — modules/vault-policy — HCL Policy Templates + Vault Policies

**Template files** (under `modules/vault-policy/templates/`):
- `base-agent.hcl.tpl` — Transit encrypt/decrypt (agent-payload, shared-memory), dynamic DB creds
- `orchestrator.hcl.tpl` — Secret-id generation + role-id reads for all classes
- `rag-agent.hcl.tpl` — MongoDB rag-writer creds, additional Transit decrypt
- `code-agent.hcl.tpl` — Gitea token read, Transit sign/verify on artifact-signing
- `tool-server.hcl.tpl` — AppRole login, token revocation, Transit encrypt/decrypt

**Resources:**
- `vault_policy.policies` — `for_each` over the computed set of all unique policy names
  (base + additive + tool-server)

Policy name → template file mapping is a module-internal local.

The `analyst` class gets only `garrison-base` (no additive template). The `analyst_base_only_valid`
output asserts this invariant is preserved.

**Parity gate:** `scripts/vault-policy-check.sh` must pass after apply.

---

## Phase 8 — modules/agent-role — AppRole Roles per Agent Class

Maps to the AppRole role creation at the bottom of `vault-bootstrap.sh`.

**Resources:**
- `vault_approle_auth_backend_role.roles` — `for_each` over `var.agent_classes`

Role properties:
- `secret_id_num_uses = 1` — one-time use (SPEC requirement)
- `secret_id_ttl = 1800` — 30-minute window in seconds
- `token_policies` — from `var.class_policy_map[each.key]`

Role-ids are stable and included in the `role_definitions` output. Secret-ids are NEVER
generated here.

**Parity gate:** `scripts/vault-policy-check.sh` AppRole login assertions must pass after apply.

---

## Phase 9 — modules/agent-skill — Skill Document Rendering + Gitea Commit

Renders per-class skill documents from a template and commits them to Gitea.

**New variables:**
- `gitea_skills_repo` (default: "garrison/skills") — owner/repo in Gitea
- `gitea_repo_branch` (default: "main")
- `gitea_provisioning_enabled` (default: false) — gates Gitea resources for bootstrap ordering

**Template file:** `modules/agent-skill/templates/skill.md.tpl`
Variables: `agent_class`, `token_ttl`, `capabilities`, `description`

**Resources:**
- `local_file.skill_docs` — always renders local skill docs for all classes
- `null_resource.gitea_commit` — commits rendered skill docs to Gitea when `gitea_provisioning_enabled=true`

`rendered_skill_paths` output updated to reflect Gitea file paths.

**Prerequisite:** Gitea must be running and a `garrison/skills` repo must exist before enabling.

---

## Phase 10 — State + CI Integration

### State
Local backend configured. `terraform.tfstate*` already gitignored.
Enterprise path: migrate to encrypted remote state (Vault, S3+KMS, or Terraform Cloud).

### ci-smoke.sh Integration

Add `GARRISON_TERRAFORM=true` code path to `scripts/ci-smoke.sh`:

```
GARRISON_TERRAFORM=true bash scripts/ci-smoke.sh
```

When set:
1. Bring up core compose services (containers only, no vault-bootstrap.sh)
2. Run `tofu -chdir=terraform init -backend=false`
3. Run `tofu -chdir=terraform apply -auto-approve`
4. Run vault-readiness.sh, vault-policy-check.sh, vault-dynamic-secrets-check.sh as parity gates
5. Continue with tool-server, open-webui startup + sanity checks

Containerized Terraform mode is supported via `GARRISON_TERRAFORM_CONTAINER=true`.
In this mode init/apply run inside a Terraform container image on the compose network
to use `http://vault:8200` directly.

When NOT set: existing script-based flow unchanged (backward compatible).

### Phase-out of vault-bootstrap.sh

Phase-out is incremental, gated by parity confirmation:

| Script | Phase-out condition |
|--------|-------------------|
| `vault-bootstrap.sh` | All parity gates pass on GARRISON_TERRAFORM path |
| Audit device setup | After vault-core parity confirmed |
| Transit key setup | After vault-transit parity confirmed |
| Policy creation | After vault-policy parity confirmed |
| AppRole role creation | After agent-role parity confirmed |

Until parity is confirmed for ALL modules, `vault-bootstrap.sh` remains the default path.

---

## Implementation Order Summary

| Step | Files | Key resources | Parity gate |
|------|-------|---------------|-------------|
| 1 | versions.tf, providers.tf, tfvars.example | required_providers, provider configs | `tofu init && tofu validate` |
| 2 | modules/infra/main.tf | null_resource.vault_health | vault health curl succeeds |
| 3 | modules/vault-core/main.tf | vault_audit, vault_auth_backend | vault-readiness.sh |
| 4 | modules/vault-pki/main.tf | vault_mount ×2, PKI chain, pki_role | PKI mount visible in Vault |
| 5 | modules/vault-secrets/main.tf | vault_mount, db connections, db roles | vault-dynamic-secrets-check.sh |
| 6 | modules/vault-transit/main.tf | vault_mount, transit keys ×3 | sanity-check transit ops |
| 7 | modules/vault-policy/main.tf + templates/ | vault_policy ×5 | vault-policy-check.sh |
| 8 | modules/agent-role/main.tf | vault_approle_auth_backend_role ×4 | vault-policy-check.sh logins |
| 9 | modules/agent-skill/main.tf + templates/ | local_file + null_resource (optional Gitea publish) | skill docs rendered locally and optionally committed to Gitea |
| 10 | variables.tf, main.tf, ci-smoke.sh | wiring + CI path | full smoke on GARRISON_TERRAFORM=true |
