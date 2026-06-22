# agentstack_secrets Role — Phase 2 Implementation

## Purpose

Provisions all secrets the agentstack chart consumes or generates, following principle #4 (OpenBao is the single source of truth for ALL secrets). No chart default secret ships; every secret is either:

- **Hooked** (has `existingSecret` in chart): generated in OpenBao → VSO VaultStaticSecret → k8s Secret
- **Hookless** (no `existingSecret` hook): generated in OpenBao → read by Ansible → injected as Helm value at deploy time (Phase 3)

Also distributes internal CAs into the agentstack namespace via trust-manager Bundles.

## Execution Order & Dependencies

**Prerequisites:**
- `preflight` role has validated armory's platform is up
- `openbao_bootstrap` has created garrison-scoped provisioner token + VSO policies + k8s-auth role
- `agentstack_keycloak` has provisioned the realm + clients + scopes + roles

**Tasks (in order):**

1. **secret_inventory** — Read-only discovery; enumerates all chart secrets + defaults + delivery methods. No changes made; output is informational + facts cached.
2. **oidc_client_secrets** — Generate/read OIDC client secrets from OpenBao, update Keycloak clients, apply VSO resources, wait for sync.
3. **postgres_secrets** — Generate/read Postgres creds from OpenBao, apply VSO + cert-manager Certificate, wait for TLS cert issuance.
4. **other_secrets** — Generate/read hookless secrets (encryptionKey, auth.nextauthSecret, Redis, SeaweedFS) from OpenBao, store as facts for Phase 3 Helm injection.
5. **trust_bundles** — Apply trust-manager Bundles (pki-int + pki-ext) to distribute CAs into the namespace.

## Key Implementation Details

### Generate-If-Absent Pattern

All secrets follow a generate-if-absent pattern (principle #2 — idempotency):

```yaml
- Read from OpenBao KV at path (GET /v1/secret/data/garrison/agentstack/...)
  Status 200 → Use existing value
  Status 404 → Generate new random value
- Write generated/existing value back to OpenBao KV (POST)
- Downstream uses the value (update Keycloak, apply VSO, inject as Helm value)
```

This ensures secrets are **stable across re-runs** (no fresh randomness per playbook execution), which is essential for Helm release convergence.

### Module-First with REST Fallback

The implementation prefers supported modules over shelling out:

| Need | Tool | Notes |
|------|------|-------|
| Apply VSO/cert-manager CRs | `kubernetes.core.k8s` (templated) | Idempotent, module-native |
| Wait for Secret/Cert | `kubernetes.core.k8s_info` | Idempotent reads |
| Update Keycloak clients with secrets | `ansible.builtin.uri` (not `keycloak_client` module) | Module doesn't support internal CA; REST with `ca_path` required |
| Generate random secrets | `ansible.builtin.uri` (OpenBao API) | Alternative: `password` lookup, but OpenBao gives audit trail |

### Internal CA Handling

Garrison must present the **internal CA bundle** for all in-cluster HTTPS calls (Keycloak, OpenBao). The bundle combines two roots:

- `openbao-ca` (CN=OpenBao-Internal-CA) — for OpenBao API `:8200`
- `keycloak-internal-tls`'s `ca.crt` (CN=Armory Root CA) — for Keycloak `:8443`

The `prepare_internal_https_caller.yml` common task (run at the start of main.yml) assemble this combined bundle at `{{ internal_ca_bundle_path }}`, which is then passed to all `uri` calls via `ca_path:`.

### VSO Resource Lifecycle

Tasks apply three VSO CRD types:

1. **VaultConnection** — cluster-scoped connection to OpenBao (TLS + CA bundle reference)
2. **VaultAuth** — namespace-scoped Kubernetes auth (maps ServiceAccount to OpenBao role)
3. **VaultStaticSecret** — namespace-scoped secret sync (KV path → k8s Secret, hooked by VSO Operator)

These are applied once and are idempotent. The VSO Operator watches them and auto-syncs the corresponding k8s Secrets. Tasks wait up to 60 seconds (30 retries × 2-second delay) for the sync to complete.

### Hookless Secrets (Helm Value Injection)

`encryptionKey` and `auth.nextauthSecret` have **no `existingSecret` hook** in the chart (confirmed 0.7.2):

- Generate in OpenBao
- Read by `other_secrets.yml` task
- Store as Ansible facts: `agentstack_helm_encryption_key`, `agentstack_helm_nextauth_secret`
- In Phase 3, the `agentstack` role (Helm deploy) will use these facts to inject `--set encryptionKey=... --set auth.nextauthSecret=...`

This is **not** a synced k8s Secret; it's a deploy-time Helm value input.

## Variables

### Inherited from group_vars/all.yml (Foundation chunk 1)

```yaml
agentstack_namespace                    # Target namespace (agentstack by default)
agentstack_ui_host                      # UI ingress hostname (derived from ARMORY_PUBLIC_DOMAIN)
keycloak_addr                           # Internal Keycloak HTTPS endpoint
openbao_addr                            # Internal OpenBao HTTPS endpoint
keycloak_tls_verify                     # true
openbao_tls_verify                      # true
internal_ca_bundle_path                 # /tmp/garrison-internal-ca.crt
openbao_kv_mount                        # secret
openbao_kv_prefix                       # garrison
openbao_provisioner_token               # Set by openbao_bootstrap
keycloak_admin_user                     # Set by openbao_bootstrap's common task
keycloak_admin_password                 # Set by openbao_bootstrap's common task
garrison_vso_sa_name                    # agentstack-vso (ServiceAccount name)
```

### Defined in role defaults/main.yml

```yaml
agentstack_openbao_kv_prefix            # garrison/agentstack
agentstack_ui_client_secret_openbao_path    # garrison/agentstack/ui-client-secret
agentstack_server_client_secret_openbao_path # garrison/agentstack/server-client-secret
agentstack_db_openbao_path              # garrison/agentstack/postgres
agentstack_encryption_key_openbao_path  # garrison/agentstack/encryption-key
agentstack_nextauth_secret_openbao_path # garrison/agentstack/nextauth-secret
agentstack_redis_openbao_path           # garrison/agentstack/redis
agentstack_seaweedfs_openbao_path       # garrison/agentstack/seaweedfs

agentstack_vault_connection_name        # agentstack-vault-connection
agentstack_vault_auth_name              # agentstack-vault-auth
agentstack_client_secrets_vso_name      # agentstack-client-secrets
agentstack_client_secrets_secret_name   # agentstack-oidc-client-secrets
agentstack_db_vso_name                  # agentstack-postgres-db-secret
agentstack_db_secret_name               # agentstack-postgres-credentials
agentstack_db_service_fqdn              # agentstack-postgresql.agentstack.svc.cluster.local
agentstack_db_tls_cert_name             # agentstack-postgresql-tls
agentstack_db_cert_issuer               # openbao-pki-internal (ClusterIssuer)

agentstack_trust_pki_int_bundle_name    # agentstack-pki-int-ca-bundle
agentstack_trust_pki_ext_bundle_name    # agentstack-pki-ext-ca-bundle
```

## Secret Inventory (Phase 2, Task 1 Output)

### OIDC Secrets

| Secret | Default | VSO? | Delivery |
|--------|---------|------|----------|
| `externalOidcProvider.uiClientSecret` | None (required) | ✓ | VSO → `agentstack-oidc-client-secrets` Secret |
| `externalOidcProvider.serverClientSecret` | None (required) | ✓ | VSO → `agentstack-oidc-client-secrets` Secret |

### Hookless Secrets

| Secret | Default | VSO? | Delivery |
|--------|---------|------|----------|
| `encryptionKey` | Empty (unsafe) | ✗ | Helm value (fact: `agentstack_helm_encryption_key`) |
| `auth.nextauthSecret` | Auto-gen (unstable) | ✗ | Helm value (fact: `agentstack_helm_nextauth_secret`) |

### Database Secrets

| Secret | Default | VSO? | Delivery |
|--------|---------|------|----------|
| `externalDatabase.password` | N/A (Postgres disabled) | ✓ | VSO → `agentstack-postgres-credentials` Secret |

### Optional Secrets (if enabled)

| Secret | Default | VSO? | Delivery |
|--------|---------|------|----------|
| `redis.auth.password` | Auto-gen (unstable) | ~ | Stored in OpenBao; VSO if redis.enabled |
| `seaweedfs.auth.admin_*` | "admin" (unsafe) | ✗ | Helm values (facts) if seaweedfs.enabled |

### Trust Bundles

| Bundle | Source | Target | Purpose |
|--------|--------|--------|---------|
| `agentstack-pki-int-ca-bundle` | `keycloak-internal-tls` (ns keycloak) | `agentstack-pki-int-ca-bundle` (ns agentstack) | Admin API provisioning |
| `agentstack-pki-ext-ca-bundle` | `armory-tls` (ns ingress-nginx) | `agentstack-pki-ext-ca-bundle` (ns agentstack) | OIDC validation (public URL) |

## Testing & Validation

### Dry-Run (Syntax Check)

```bash
ansible-playbook --syntax-check ansible/playbooks/site.yml
ansible-lint ansible/playbooks/site.yml ansible/roles/
```

### Full Execution (on VM in armory's k3s cluster)

```bash
# Run Phase 2 only (assumes Phase 1 passed)
cd /opt/project-garrison
ansible-playbook -i ansible/inventories/development ansible/playbooks/site.yml -t agentstack_secrets -v

# Or run full pipeline (preflight → openbao_bootstrap → agentstack_keycloak → agentstack_secrets)
ansible-playbook -i ansible/inventories/development ansible/playbooks/site.yml -v
```

### Post-Execution Checks

```bash
# Verify Secrets created
kubectl get secrets -n agentstack
kubectl describe secret agentstack-oidc-client-secrets -n agentstack
kubectl describe secret agentstack-postgres-credentials -n agentstack

# Verify VSO resources synced
kubectl get VaultStaticSecret -n agentstack
kubectl get VaultConnection -n agentstack
kubectl get VaultAuth -n agentstack

# Verify trust-manager Bundles synced
kubectl get secrets agentstack-pki-int-ca-bundle agentstack-pki-ext-ca-bundle -n agentstack
kubectl describe secret agentstack-pki-int-ca-bundle -n agentstack | grep -A5 Data

# Verify Postgres cert issued
kubectl describe certificate agentstack-postgresql-tls -n agentstack

# Verify facts cached for Phase 3
ansible-inventory -i ansible/inventories/development --host localhost 2>/dev/null | jq '.agentstack_helm_encryption_key'
```

## Known Limitations & Future Work

1. **Conditional secrets (Redis, SeaweedFS)** — Currently all generated; Phase 3 must check `redis.enabled` and `seaweedfs.enabled` before using. If either is disabled, its OpenBao KV path is harmless (created but unused).

2. **Phoenix secrets** — Currently unexamined (phoenix.enabled: false default). If Phoenix is enabled in Phase 3+, this role must be extended to discover + provision Phoenix secrets. Flag with TODO in ticket.

3. **Keycloak client secret rotation** — The `changed_when: false` on client secret updates means Ansible won't report a change even when the secret is rotated. This is correct behavior (the secret value is stable from OpenBao; we just store it in Keycloak), but it may surprise operators. Document in runbooks.

4. **VSO operator health** — Tasks assume VSO is installed and functional. If VSO is down, Secret sync will timeout. Add a readiness check in Phase 3 or handle gracefully.

5. **cert-manager Certificate auto-renewal** — The self-rolled Postgres TLS cert is issued once and auto-renewed by cert-manager. This is correct; no action needed.

## Principles Enforced

✓ **Module-first** — All CRs applied via `kubernetes.core.k8s` (templated), not `kubectl apply`.
✓ **Idempotency** — Generate-if-absent pattern; all reads are `changed_when: false`; no fresh randomness per run.
✓ **OpenBao as truth** — Every secret originates in OpenBao; no chart default accepted.
✓ **Audit trail** — All secrets logged to OpenBao audit device (armor file + daily rotation).
✓ **Least privilege** — VSO uses Kubernetes auth role (garrison) tied to a scoped policy; no root token stored.
✓ **Self-contained** — No cross-repo imports; all patterns vendored into garrison's `common` role.

## Integration with Phase 3

After Phase 2 completes:

- **agentstack_db** role will consume:
  - `agentstack-postgres-credentials` Secret (username, password)
  - `agentstack-postgresql-tls` Certificate (TLS cert for DB service)

- **agentstack** role (Helm deploy) will consume:
  - `agentstack-oidc-client-secrets` Secret (uiClientSecret, serverClientSecret)
  - Facts: `agentstack_helm_encryption_key`, `agentstack_helm_nextauth_secret`
  - Trust Bundles: `agentstack-pki-int-ca-bundle`, `agentstack-pki-ext-ca-bundle`
