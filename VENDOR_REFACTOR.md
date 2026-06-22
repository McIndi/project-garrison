# Garrison Vendor Refactor — Removing Armory Imports

**Completed:** 2026-06-21

## Problem
The initial `teardown.yml` violated AGENTS.md principle by importing tasks from `../../project-armory/...`, which:
1. Breaks if armory's repo location changes
2. Depends on armory's file structure (not guaranteed)
3. Fails when armory's files are unavailable

## Solution
Vendored garrison-local `common` role containing three reusable task files:
- `prepare_internal_https_caller.yml` — Fetch armory's internal CA bundle
- `prepare_openbao_provisioner_token.yml` — Read root token (break-glass), mint scoped provisioner token
- `prepare_keycloak_bootstrap_admin.yml` — Read Keycloak bootstrap admin credentials

## Changes

### 1. Created `ansible/roles/common/` (library role)
```
common/
  defaults/
    main.yml                              # Vendored defaults for all common tasks
  tasks/
    main.yml                              # Role entry point (no-op; tasks are included)
    prepare_internal_https_caller.yml     # Fetch CA from cert-manager
    prepare_openbao_provisioner_token.yml # Bootstrap garrison's OpenBao identity
    prepare_keycloak_bootstrap_admin.yml  # Read KC bootstrap admin creds
  README.md                               # Documentation of vendored patterns
```

### 2. Updated `openbao_bootstrap` role
- Replaced duplicate CA bundle + root token logic with `include_tasks` calls to common
- Kept VSO Kubernetes auth setup in the role (specific to openbao_bootstrap, not reusable)
- Cleaner, focused role now: foundation → K8s auth wiring

### 3. Updated `teardown.yml` playbook
- Removed both armory imports:
  - ~~`import_tasks: ../../project-armory/ansible/roles/common/tasks/prepare_internal_https_caller.yml`~~
  - ~~`import_tasks: ../../project-armory/ansible/roles/common/tasks/load_openbao_token_for_admin_client.yml`~~
- Added garrison-local includes:
  - `include_tasks: ../roles/common/tasks/prepare_internal_https_caller.yml`
  - `include_tasks: ../roles/common/tasks/prepare_openbao_provisioner_token.yml`
  - `include_tasks: ../roles/common/tasks/prepare_keycloak_bootstrap_admin.yml`
- Updated Keycloak realm deletion to use `{{ keycloak_admin_user }}` / `{{ keycloak_admin_password }}` facts (from common task) instead of env vars
- Updated OpenBao KV cleanup to use `{{ openbao_provisioner_token }}` (scoped token, not admin token)
- KV path now derived from common defaults: `{{ openbao_kv_mount }}/data/{{ openbao_kv_prefix }}`

### 4. Updated `AGENTS.md`
- Clarified "sole documented exception" (break-glass root read in `prepare_openbao_provisioner_token.yml`)
- Emphasized vendoring approach over cross-repo imports

## Idempotency & Reusability

All common tasks are idempotent and can be included by any phase/play:
- **CA bundle:** Read-copy-verify (safe to re-run)
- **OpenBao provisioner token:** Policy created if absent, token minted fresh each run (safe to re-run)
- **Keycloak admin:** Secret read and facts set (safe to re-run)

## Self-Containment Guarantee

✅ **No cross-repo imports remaining** — both `site.yml` (via openbao_bootstrap) and `teardown.yml` now use garrison-local tasks.

✅ **Break-glass exception documented** — The one-time root token read from `/opt/openbao/init-keys.yml` is the **only** touch of an armory artifact, clearly marked in code and docs.

✅ **Patterns, not files** — Garrison owns all copies; if armory changes, garrison is unaffected.

## Future Phases
As garrison grows, new vendored patterns can be added to `common/tasks/`:
- Postgres StatefulSet (from armory's keycloak role)
- trust-manager Bundle patterns
- Ingress/hostAlias patterns
- Service ClusterIP lookup patterns

All following the same principle: **vendor copies, never cross-repo imports**.
