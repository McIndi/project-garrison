---
# Garrison Common Role — Vendored Armory Patterns

This role contains **garrison-local copies** of patterns from armory, adapted and parameterized for garrison's use. These tasks are vendored (never imported from armory's repo by path) to ensure self-containment and maintainability.

## Principle

Per AGENTS.md: **Reuse armory's *patterns*, not its *files in place*.** The common role achieves this by vendoring copies of:
- Internal CA bundle acquisition (from cert-manager)
- OpenBao break-glass bootstrap (read root token, mint scoped provisioner identity)
- Keycloak bootstrap admin credentials (for realm deletion, seed user creation)

## Tasks

### `prepare_internal_https_caller.yml`
Fetches armory's internal (pki-int) CA bundle from the `cert-manager` secret and writes it to disk.
- **Why:** `community.general.keycloak_*` modules need the internal CA for HTTPS validation to `keycloak-service.keycloak.svc.cluster.local:8443`.
- **Pattern source:** armory's `common/tasks/prepare_internal_https_caller.yml`
- **Garrison adaptation:** Parameterized secret name/namespace; uses `kubernetes.core.k8s_info` module.
- **Used by:** `openbao_bootstrap` role, `teardown.yml` playbook, and any phase that touches armory's Keycloak.

### `prepare_openbao_provisioner_token.yml`
Garrison's OpenBao bootstrap: reads the root token (one-time, break-glass), creates a garrison-provisioner policy, and mints a scoped token for this run's KV writes.
- **Why:** Establishes garrison's self-owned OpenBao identity (never reuses armory's provisioner token or policies).
- **Pattern source:** armory's `common/tasks/load_openbao_root_token.yml` + OpenBao policy creation
- **Garrison adaptation:** 
  - Reads root from `/opt/openbao/init-keys.yml` (Vault-encrypted) — the sole break-glass exception
  - Creates garrison-specific policy (`garrison-provisioner`) scoped to `secret/garrison/*`
  - Mints a short-lived scoped token (3600s default) for KV writes
  - All tokens held in-memory (`no_log: true`), never persisted
- **Used by:** `openbao_bootstrap` role, `teardown.yml` playbook (for KV cleanup).

### `prepare_keycloak_bootstrap_admin.yml`
Reads Keycloak bootstrap admin credentials from a k8s Secret (created by armory).
- **Why:** Teardown needs admin creds to delete the `agentstack` realm. Credentials are sourced from a k8s Secret, not env vars (more robust, auditable).
- **Pattern source:** armory's pattern of storing sensitive bootstrap creds in k8s Secrets
- **Garrison adaptation:** 
  - Reads from `keycloak-bootstrap-admin` Secret in `keycloak` namespace
  - Parameterized secret/key names
- **Used by:** `teardown.yml` playbook (realm deletion).

## Integration

All three tasks are included (not imported as a role) by plays that need them:

```yaml
# In site.yml (openbao_bootstrap role):
- name: Prepare internal HTTPS caller
  ansible.builtin.include_tasks: ../../../common/tasks/prepare_internal_https_caller.yml

- name: Prepare OpenBao provisioner token
  ansible.builtin.include_tasks: ../../../common/tasks/prepare_openbao_provisioner_token.yml

# In teardown.yml:
- name: Prepare internal HTTPS caller
  ansible.builtin.include_tasks: ../roles/common/tasks/prepare_internal_https_caller.yml

- name: Prepare OpenBao provisioner token
  ansible.builtin.include_tasks: ../roles/common/tasks/prepare_openbao_provisioner_token.yml

- name: Prepare Keycloak bootstrap admin
  ansible.builtin.include_tasks: ../roles/common/tasks/prepare_keycloak_bootstrap_admin.yml
```

## Defaults

All configurable paths and identities are defined in `defaults/main.yml`:
- `internal_ca_*`: cert-manager secret name/namespace/key
- `openbao_*`: OpenBao paths, policies, TTLs
- `keycloak_*`: Keycloak secret name/namespace/keys

Override via inventory (`group_vars`), CLI (`-e`), or role/play defaults.

## Idempotency

All tasks are idempotent:
- **Internal CA:** Reads, copies to disk (idempotent if already present).
- **OpenBao provisioner:** Policy created if absent (GET→PUT on 404), token minted fresh each run (intentional re-mint for cleanup).
- **Keycloak admin:** Reads secret (idempotent fact).

## Self-Containment Guarantee

These tasks **never** import from `../project-armory/...`. They are copies of armory's *patterns*, not filesystem pointers to armory's *files*. If armory's repo moves or changes, garrison is unaffected.

## Future Additions

As garrison grows (Phases 2–4), additional vendored patterns may be added here:
- Postgres StatefulSet (from armory's keycloak role)
- trust-manager Bundle patterns
- Ingress/hostAlias patterns
