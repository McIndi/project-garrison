# 001 — Deploy Agent Stack against armory's external Keycloak

**Status:** open · **Created:** 2026-06-18

## Goal

Stand up `project-garrison` as an Ansible repo that deploys the BeeAI / Agent
Stack Helm chart (`agentstack` 0.7.1, the published registry latest — 0.7.2 is
unreleased main-branch and 404s on pull) with its bundled Keycloak **disabled**,
pointed at the external Keycloak owned by `project-armory`. "Done" = a user can
log into the Agent Stack UI via OIDC against the `agentstack` realm, and the
server accepts the token (no 401) end-to-end. **Browser E2E validated
2026-06-23. Remaining Phase 4 gate: beeai CLI login (ROPC finding).**

## Context

- Full requirement extraction lives in
  [`agentstack-keycloak-reqs-for-garrison.md`](../../agentstack-keycloak-reqs-for-garrison.md).
  Read it first; this ticket is the *build plan*, that doc is the *spec*.
- Garrison is currently empty (only the reqs doc). Armory next door
  (`../project-armory`) is a mature Ansible reference architecture and **owns the
  shared infra** (k3s, OpenBao, Keycloak operator, nginx-ingress, VSO,
  cert-manager, trust-manager). Garrison does **not** redeploy any of that — it
  consumes it.
- **Key accelerator:** armory's
  [`headlamp/tasks/oidc_client.yml`](../../../project-armory/ansible/roles/headlamp/tasks/oidc_client.yml)
  is ~90% of the realm/client provisioner we need — same Keycloak, same admin
  token flow, same idempotent GET→POST/PUT REST pattern, same OpenBao internal-CA
  handling. We adapt it from the `armory` realm to a new `agentstack` realm.

### Locked decisions (defaults — parameterized, cheap to change later)

| Decision | Value | Source |
|---|---|---|
| AgentStack namespace | `agentstack` | reqs §5 (must be fixed up front) |
| UI ingress host | `agentstack.<armory-domain>` | reqs §4.6 (garrison's to pick) |
| Run model | **Separate repo, deploy-only, runs inside armory's VM against armory's kubeconfig, as a follow-on after armory's `site.yml`** | DECISION 2026-06-19 / reqs §5 |
| Implementation vehicle | Ansible, mirroring armory | reqs is written entirely around armory reuse |
| Realm bootstrap | `KeycloakRealmImport` CR, then REST for clients/scopes | reqs §6 |
| `directAccessGrantsEnabled` (ROPC) on server client | **start `false`** | reqs §3.2 / §7 — not knowable statically |
| AgentStack Postgres | **`postgresql.enabled: false`; self-roll `pgvector/pgvector:pg16` StatefulSet via armory's pattern, wire via `externalDatabase`** | DECISION 2026-06-20 — avoid Bitnami subchart; pgvector image required by `create-pgvector-extension` init container (see Notes) |

## Engineering principles (apply from the start — non-negotiable)

1. **Supported modules over shelling out.** Prefer declarative
   `kubernetes.core.*` / `community.general.keycloak_*` modules to
   `ansible.builtin.command`/`shell` wrapping `kubectl`/`helm`/`curl`. This is a
   deliberate improvement over armory, which renders `.j2` → `kubectl apply -f -`
   and runs `helm` via `command`. These modules are **idempotent by
   construction** (they diff desired vs actual and report `changed` accurately),
   which is the whole point.

   | Need | Use | Not |
   |---|---|---|
   | Install/upgrade the chart | `kubernetes.core.helm` (+ `kubernetes.core.helm_repository`) | `command: helm upgrade` |
   | Apply CRs/manifests (RealmImport, VaultStaticSecret, Bundle, Ingress) | `kubernetes.core.k8s` with templated `definition` | `template` → `kubectl apply -f -` |
   | Read a Secret / Service ClusterIP | `kubernetes.core.k8s_info` | `command: kubectl get ... -o jsonpath` |
   | hostAlias patch on Deployments | `kubernetes.core.k8s` (`state: patched`, strategic merge) | `command: kubectl patch` |
   | Realm, clients, client scopes, roles, role-mappings, seed user | `community.general.keycloak_realm`, `keycloak_client`, `keycloak_clientscope`, `keycloak_role`/`keycloak_realm_role`, `keycloak_user` | hand-rolled GET→POST/PUT `uri` calls |

2. **Idempotency is a design constraint, not a cleanup pass.** Every task must be
   safely re-runnable:
   - Reads/lookups: `changed_when: false`.
   - Any unavoidable `command`/`shell`: set explicit `creates:`/`changed_when:`/
     `failed_when:` — never leave the default "always changed."
   - **No fresh randomness on every run.** Client secrets, `encryptionKey`,
     `nextauthSecret` are *generate-if-absent → persist in OpenBao → read back*,
     never regenerated each run (that would silently rotate creds and make
     deploys non-idempotent). Mirror the headlamp "generate only when the client
     doesn't already exist" guard.
   - Helm values must be stable inputs; never `--set` a freshly-generated value
     (`encryptionKey` comes from OpenBao precisely so the release converges).

3. **One known caveat to verify in Phase 1, not assume away.** The
   `community.general.keycloak_*` modules talk to armory's Keycloak over HTTPS on
   8443 with an **internal (pki-int) CA**. Confirm the installed collection
   version honours a custom CA bundle for the admin connection (`ca_path`, or
   `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE` in the task `environment:`). If a given
   module can't present the internal CA, that single step — and **only** that
   step — falls back to the headlamp `uri` REST pattern with `ca_path:`; do not
   abandon the module approach wholesale. Pin the collection versions in
   `requirements.yml`.

4. **OpenBao is the single source of truth for ALL secrets — no chart default,
   no chart auto-gen accepted (DECISION 2026-06-20).** Every secret the chart
   consumes or would generate is instead **generated in / sourced from OpenBao**
   (generate-if-absent, per principle #2). This buys two things: uniform audit
   provenance (every secret read lands in armory's OpenBao audit device) and a
   forcing function to **discover and replace every insecure default the chart
   ships** (e.g. Postgres `admin-password`/`password`, SeaweedFS
   `agentstack-admin-user`/`agentstack-admin-password`). Delivery splits by
   whether the chart exposes an `existingSecret` hook:
   - **Has `existingSecret`** (OIDC client secrets, `postgresql.auth.existingSecret`,
     Redis auth, etc.) → OpenBao KV → **VSO `VaultStaticSecret`** → referenced k8s
     Secret.
   - **No `existingSecret`** (`encryptionKey`, `auth.nextauthSecret` — reqs §4.5)
     → OpenBao KV → **read by Ansible, injected as a Helm value at deploy time**
     (NOT a synced Secret; do not fall into the §4.5 trap). `nextauthSecret` is
     therefore sourced from OpenBao too, **not** left to chart auto-gen.
   - **No hook + no value input** (rare) → flag for a post-deploy patch or a
     targeted override; record it in the secret inventory below.

## Architecture

**Garrison has no VM of its own.** It deploys into armory's existing single-node
k3s — which, since armory is one Fedora Vagrant VM, is the *same VM*. Garrison's
Ansible runs **inside armory's VM** (repo mounted alongside armory under
`/vagrant`), uses **armory's kubeconfig**, and runs as a **follow-on after
armory's `site.yml`**. So garrison clones armory's *repo conventions* (`.env`/
env-sourcing, `ansible/playbooks/site.yml`, `common` task patterns, dev
inventory, lint config) **but NOT a `Vagrantfile`** — and instead of an
`env_guard` that stands up a VM, a **light `preflight` role asserts armory's
platform is already up** (Keycloak/OpenBao/ingress/VSO/trust-manager reachable;
kubeconfig valid). It adds only three new roles, since armory provides the
platform:

```
ansible/roles/
  agentstack_keycloak/   # realm + 2 clients + audience scope/mapper + 2 roles + seed admin (REST, on armory KC)
  agentstack_secrets/    # OpenBao KV writes + VSO VaultStaticSecret + trust-manager Bundles (pki-int + pki-ext)
  agentstack_db/         # self-rolled pgvector/pgvector:pg16 StatefulSet (armory pattern) + pki-int TLS; NOT the Bitnami subchart
  agentstack/            # Helm release (external OIDC values, postgresql.enabled:false→externalDatabase) + hostAlias patch + UI ingress
```

**No Bitnami runtime dependency.** The chart's bundled `postgresql` is the Bitnami
subchart (`oci://registry-1.docker.io/bitnamicharts`, 16.x.x) — disabled, and
replaced by a self-rolled `postgres:16` StatefulSet copied from armory's keycloak
role (`postgres.yaml.j2`): official image, OpenBao/VSO creds, optional `pki-int`
TLS already implemented. The other subcharts are NOT Bitnami (`redis`→cloudpirates,
`seaweedfs`→official, `phoenix`→arizephoenix), so they're used as-is (subject to
the Phase 2 secret inventory). `common` is `bitnami-common`, a library chart pulled
only at `helm dependency build` (no runtime image) — low risk, but the bitnamicharts
OCI registry must be reachable at build time.

The internal-CA acquisition + OpenBao-token logic is **vendored (copied) into
garrison** as its own `common` role/tasks — **never imported from armory's repo by
filesystem path** (armory's location isn't guaranteed; cross-repo path imports
broke teardown.yml on 2026-06-20). Adapt armory's *pattern*
(`prepare_internal_https_caller.yml`, `load_openbao_*_token.yml`) into
garrison-local, parameterized tasks. The acquired CA bundle is what the
`community.general.keycloak_*` modules consume (`ca_path` / `REQUESTS_CA_BUNDLE`).

Add a `requirements.yml` pinning `kubernetes.core` and `community.general`
(for the `keycloak_*` modules), installed in the VM via
`ansible-galaxy collection install -r requirements.yml`. Both Python deps
(`kubernetes`, `PyYAML`) must be present in the VM's Ansible interpreter.

## Tasks (phased to retire the two known unknowns early)

### Phase 0 — Scaffold (~½ day)  ← deploy-only, NO Vagrantfile/VM
- [X] Clone armory's *conventions* into garrison: `.env.example` (incl. pointer
      to armory's kubeconfig), `common` task patterns, `ansible/playbooks/site.yml`,
      dev inventory, `.ansible-lint`, `.yamllint`. **Do NOT** add a `Vagrantfile`
      or VM-provisioning — garrison runs inside armory's VM.
- [x] `preflight` role (replaces armory's heavyweight `env_guard`): assert armory
      is up before doing anything — kubeconfig valid, and via
      `kubernetes.core.k8s_info` confirm the Keycloak `Service`/CR, OpenBao,
      nginx-ingress, VSO, and trust-manager are present/Ready. Fail fast with a
      clear "run armory's site.yml first" message if not.
- [x] Add `requirements.yml` with `kubernetes.core` + `community.general`
      during development (intentionally unpinned to test latest; pin before demo);
      ensure `kubernetes`/`PyYAML` present in the VM's Ansible interpreter (these
      are already in armory's VM — verify, don't re-provision a VM).
- [x] Write `AGENTS.md`: records module-first + idempotency, the deploy-only/
      same-VM run model, the two-loop dev workflow, all-secrets-via-OpenBao, the
      no-Bitnami Postgres decision, and key decisions — so handoffs stay lean
      (agents auto-read it). Drafted 2026-06-20, pending your review.
- [X] `teardown.yml` playbook (garrison's analog of armory's
      `teardown_k3s_workloads.yml`, gated by `-e teardown_confirm=true`): helm
      uninstall the release, delete the `agentstack` ns, `keycloak_realm:
      state=absent` for the `agentstack` realm, and clean garrison's OpenBao KV
      paths. This is what makes the inner loop `teardown.yml` → `site.yml` without
      touching armory.
- [X] `bringup-all` convenience wrapper (script or Make target) documenting the
      forced outer-loop order: armory `site.yml` → garrison `site.yml` (since an
      armory rebuild wipes garrison's realm + KV state).
- [X] Green `ansible-playbook --syntax-check` + `ansible-lint` before any logic.

### Phase 1 — Realm provisioner `agentstack_keycloak` (~1 day)  ← retires §3.4 audience bug + §module-CA caveat
- [x] **First, prove the module→internal-CA path** (the principle #3 caveat):
      Implemented in `ca_proof.yml`: installs the combined CA bundle to the Fedora
      system trust store (`/etc/pki/ca-trust/source/anchors/` + `update-ca-trust
      extract`) — this is the correct fix because `community.general.keycloak_*`
      uses `open_url` (NOT Python `requests`) and does NOT honour
      `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE`. After trust-store update, `open_url`
      respects the OS ca-bundle, so `validate_certs: true` works. The proof call
      (`keycloak_realm` against `master`) runs immediately after to confirm.
      **Needs VM validation** to confirm the trust-store approach works end-to-end.
- [x] Readiness assertion (write failing first): the `ca_proof.yml` assert fires
      if the `keycloak_realm` module call is skipped/undefined; realm existence
      check is implicit — `keycloak_realm state: present` on `agentstack` will
      fail fast if Keycloak is unreachable.
- [x] Realm `agentstack`: `community.general.keycloak_realm` in `realm.yml`
      (NO `clientScopes` block); audit events (`eventsEnabled`, `eventsListeners`,
      `adminEventsEnabled`, `adminEventsDetailsEnabled`, `eventsExpiration`) set
      in the same call — garrison owns this realm end-to-end.
- [x] Both clients via `community.general.keycloak_client` in `clients.yml`:
      - `agentstack-ui`: confidential, `standard_flow_enabled: true`,
        `direct_access_grants_enabled: false`, redirect/web-origins scoped to the
        real UI host; `default_client_scopes` includes standard OIDC scopes +
        `agentstack-server-audience`.
      - `agentstack-server`: confidential, `standard_flow_enabled: false`,
        `service_accounts_enabled: true`, `direct_access_grants_enabled: false`.
- [x] Client scope `agentstack-server-audience` via
      `community.general.keycloak_clientscope` in `client_scopes.yml` with
      `oidc-audience-mapper`, `included.custom.audience: agentstack-server`
      (**literal client id, NOT a URL** — the §3.4 fix); assigned as a **default**
      scope on `agentstack-ui` via `default_client_scopes` in `clients.yml`
      (scope must be created in `client_scopes.yml` before `clients.yml` runs).
- [x] Realm roles `agentstack-admin` + `agentstack-developer` via
      `community.general.keycloak_role` in `roles_and_users.yml`; seed admin user
      created with `community.general.keycloak_user` with `realm_roles:
      [agentstack-admin]`; password generated-if-absent in OpenBao KV and read
      back each run (stable value — no fresh random; uses `openbao_provisioner_token`
      from `openbao_bootstrap` role).
- [x] **Audit events** set directly on the `keycloak_realm` call (see realm item
      above). `jboss-logging` in `eventsListeners`, 30-day `eventsExpiration`.

### Phase 2 — Secrets + trust `agentstack_secrets` (~½ day)
- [X] **Secret inventory & default-hardening (discovery — do this FIRST).**
      Enumerate **every** secret the chart consumes or auto-generates from
      `values.yaml` + subchart defaults: OIDC client secrets, `encryptionKey`,
      `auth.nextauthSecret`, Postgres (`postgresPassword`/`password`, default
      `admin-password`/`password`), SeaweedFS (`accessKeyID`/`accessKeySecret`,
      default `agentstack-admin-user`/`agentstack-admin-password`), Redis auth
      (if enabled), Phoenix, and anything else discovered. For each, record:
      current default (flag insecure ones), whether an `existingSecret` hook
      exists, and the chosen delivery (VSO vs deploy-time Helm value, per
      principle #4). Output is a small table in this ticket; it is the
      authoritative map for the tasks below. **No chart default secret ships.**
      Note: Postgres creds are NOT delivered to the Bitnami subchart — that
      subchart is disabled (see `agentstack_db` decision); the DB password is the
      self-rolled StatefulSet's OpenBao/VSO secret, surfaced to the chart via
      `externalDatabase.existingSecret`.
- [X] Generate-if-absent the two client secrets (never re-randomize on re-run),
      write to OpenBao KV; `VaultStaticSecret` + `Bundle` CRs applied with
      `kubernetes.core.k8s` (templated `definition`). Resulting k8s Secret in
      `agentstack` ns must carry keys **exactly** `uiClientSecret` /
      `serverClientSecret` (reqs §2, §7 confirmed).
- [X] Generate-if-absent and deliver every other inventoried secret per its
      classification: `existingSecret`-capable ones (Postgres, Redis, …) via VSO
      `VaultStaticSecret`; hookless ones (`encryptionKey`, `auth.nextauthSecret`)
      read from OpenBao and injected as Helm values at deploy time.
- [X] trust-manager `Bundle`s into `agentstack` ns: `pki-int` (admin API),
      `pki-ext` (OIDC validation over public URL).
- [X] **AgentStack Postgres creds + TLS cert** (feeds `agentstack_db`):
      generate-if-absent DB user/password in OpenBao KV → VSO `VaultStaticSecret`
      → k8s Secret (keys the chart's `externalDatabase.existingSecret` expects);
      cert-manager `Certificate` from `openbao-pki-internal` (SAN = the DB service
      FQDN in `agentstack` ns) for `ssl=on`. Both copied from armory's keycloak
      role (`vaultstaticsecret.yaml.j2`, the `keycloak_pg_tls_*` Certificate).
- [X] `encryptionKey` specifically: generate-if-absent in OpenBao, **inject as a
      Helm value at deploy time** (NOT a synced Secret — no `existingSecret` hook,
      fails silently when empty; reqs §4.5). `auth.nextauthSecret` is delivered
      the same way (OpenBao → Helm value), **not** left to chart auto-gen — so it
      gains audit provenance like everything else.

### Phase 3 — Deploy `agentstack` (~1 day)
- [x] **`agentstack_db`: self-rolled Postgres (before the Helm release).** Apply
      the `pgvector/pgvector:pg16` Service + StatefulSet (copied from armory
      `keycloak/templates/postgres.yaml.j2`) into `agentstack` ns via
      `kubernetes.core.k8s`, consuming the OpenBao/VSO DB Secret + `pki-int`
      Certificate from Phase 2; run with `ssl=on`. This replaces the disabled
      Bitnami subchart. (`postgres:16` is NOT sufficient — the chart's
      `create-pgvector-extension` init container requires pgvector.)
- [x] `kubernetes.core.helm` release (with `kubernetes.core.helm_repository` for
      the chart repo) using `values:`/`values_files:` — `keycloak.enabled: false`,
      **`postgresql.enabled: false`** + `externalDatabase.{host,port,user,database,
      existingSecret,ssl: true,sslRootCert}` pointed at the self-rolled DB
      (host = DB service FQDN; `sslRootCert` = the `pki-int` CA from the
      trust-manager Bundle),
      `externalOidcProvider.{issuerUrl,uiClientId,serverClientId,existingSecret}`,
      `auth.validateAudience: false` (server checks URL-shaped aud, not client-ID string — see notes 2026-06-23), `auth.basic.enabled: false` (OIDC-only),
      `trustProxyHeaders: true`. Leave `AUTH__OIDC__INSECURE_TRANSPORT` default
      (issuer is HTTPS). Do **not** patch Deployments for proxy env (chart-native
      in 0.7.2, reqs §4.4).
- [x] hostAlias patch on UI + server Deployments mapping `<armory-host>` →
      ingress-nginx ClusterIP, via `kubernetes.core.k8s` (`state: patched`,
      strategic merge) — get the ClusterIP with `kubernetes.core.k8s_info`, not
      `kubectl get -o jsonpath`. (Logic from `headlamp/tasks/deploy.yml`
      296–333, but module-based.)
- [x] UI ingress: `ingressClassName: nginx`, TLS cert from
      `openbao-pki-external` ClusterIssuer, SAN = UI host; keep host consistent
      with `agentstack-ui` redirectUris/webOrigins + cert SAN.

### Phase 4 — Runtime verification (~½ day)  ← retires §3.2 ROPC unknown
- [x] Browser login E2E against the UI ingress; confirm redirect → token → app.
      **VALIDATED 2026-06-23** — full OIDC redirect, Keycloak login, session cookie
      issued, UI loads. Resolved a chain of 6 post-login 401/500 errors (see notes).
- [x] Decode the **access** token; assert `aud` contains `agentstack-server` and
      the API returns 200 (not 401). **VALIDATED 2026-06-23** — JWE session cookie
      decrypted; access token confirmed `aud=['agentstack-server','account']`
      (Phase 1 audience mapper correct). API 200 confirmed after `validateAudience`
      fix (see notes).
- [ ] Test the beeai CLI login. **This is the only way to learn** whether ROPC is
      actually needed on `agentstack-server`. If CLI login fails with an auth error,
      flip `directAccessGrantsEnabled: true` on `agentstack-ui` (not server) and
      re-test; otherwise leave it off and record the finding here.
      **See notes 2026-06-23 for expected CLI test procedure.**
- [x] `readiness_check`-style assertions wired into the playbook.

## Notes

_(running log — decisions, blockers, findings)_

- 2026-06-18 — Ticket created from reqs doc. Defaults locked: ns `agentstack`,
  UI host `agentstack.<armory-domain>`, ROPC starts disabled. Estimated
  ~3.5–4 focused days; the two static-unknowables (audience mapper correctness,
  ROPC need) deliberately surface in Phase 1 and Phase 4, not at the end.
- 2026-06-18 — Convention added: **module-first + idempotency by design.** Prefer
  `kubernetes.core.*` and `community.general.keycloak_*` over shelling out to
  kubectl/helm/curl (a deliberate upgrade over armory's `command`-based pattern).
  One thing to verify in Phase 1: whether the keycloak modules accept the pki-int
  internal CA over 8443; `uri`+`ca_path` is the per-step fallback only.
- 2026-06-19 — **DECISION: garrison co-deploys into armory's cluster/VM**,
  deploy-only. No Vagrantfile/VM of its own; runs inside armory's VM against
  armory's kubeconfig as a follow-on after armory's `site.yml`. `env_guard`
  becomes a light `preflight` that *asserts* armory's platform is up rather than
  provisioning it. Reflected in reqs §5 and Phase 0 above. Separate-cluster path
  is de-scoped.
- 2026-06-21 — **OpenBao auth: garrison self-bootstraps (DECISION).** Mirror
  armory's pattern (scoped provisioner token minted from root + per-consumer VSO
  k8s-auth roles) but with garrison-OWNED artifacts — never reuse armory's token/
  policies. Garrison runs a one-time privileged bootstrap that reads the OpenBao
  **root token from a k8s Secret** (garrison uses it once → creates its own
  `garrison-provisioner` policy/token + read-policies + k8s-auth roles → never
  persists root). **RESOLVED 2026-06-21: read root from the Vault file**, not a
  k8s Secret (no such Secret exists). Garrison vendors armory's break-glass
  `load_openbao_root_token.yml` pattern: `ansible-vault decrypt` of
  `/opt/openbao/init-keys.yml` with `/opt/openbao/.vault-pass` (both root-readable
  VM files; paths via vars), `no_log`, as root. Root used once → mint a scoped
  `garrison-provisioner` token + write garrison policies + VSO k8s-auth roles →
  root never persisted. This is garrison's sole permitted touch of an armory
  artifact (documented exception in AGENTS.md). Day-to-day KV writes use the
  scoped token, not root; reads use VSO k8s-auth. This unblocks teardown's KV
  cleanup and all of Phase 2.
- 2026-06-20 — **teardown.yml broke: cross-repo path import.** Copilot built
  teardown.yml importing `../../project-armory/ansible/roles/common/tasks/...`,
  which resolves to a non-existent path on the VM and violates self-containment.
  Root cause: teardown jumped ahead of its foundation (the vendored internal-CA +
  admin-token plumbing). Corrective sequence: (1) build the CA-proof spike as a
  **garrison-vendored** `common` (CA bundle from `openbao-ca` secret; admin creds
  from `keycloak-bootstrap-admin` secret, NOT env vars); (2) rebuild teardown on
  top. Guard added to AGENTS.md: never path-reference armory's repo — vendor
  copies. Also note: `.env.example` assumes `/vagrant/project-*` but the VM has
  garrison at `/opt/garrison/project-garrison` — verify/repair the env paths.
- 2026-06-21 — **Vendor refactor COMPLETE.** Removed all armory imports from
  garrison. Created garrison-local `common` role with three vendored tasks:
  `prepare_internal_https_caller.yml`, `prepare_openbao_provisioner_token.yml`,
  `prepare_keycloak_bootstrap_admin.yml`. Both `site.yml` (via openbao_bootstrap)
  and `teardown.yml` now use garrison-local includes. Break-glass root token read
  is sole documented exception (noted in code + AGENTS.md). No cross-repo imports
  remaining. See VENDOR_REFACTOR.md for details.
- 2026-06-22 — **Phase 1 implemented (needs VM validation).** Built the full
  `agentstack_keycloak` role: `defaults/main.yml`, `tasks/ca_proof.yml`,
  `tasks/realm.yml`, `tasks/client_scopes.yml`, `tasks/clients.yml`,
  `tasks/roles_and_users.yml`, updated `tasks/main.yml` orchestrator. Key
  decisions made during implementation:
  (1) **CA module caveat resolved by design**: `community.general.keycloak_*`
  uses `open_url` (not Python `requests`), so `REQUESTS_CA_BUNDLE` is useless.
  Fix: install the combined CA bundle into the Fedora system trust store
  (`/etc/pki/ca-trust/source/anchors/` + `update-ca-trust extract`) in
  `ca_proof.yml` before any module calls. `open_url` respects the OS ca-bundle.
  Proof call (`keycloak_realm` on `master`) confirms it works.
  (2) **Realm uses `community.general.keycloak_realm`** (not `KeycloakRealmImport`
  CR) — simpler, fully idempotent, handles audit events in the same call.
  (3) **Client scope created before clients** so `default_client_scopes` on
  `agentstack-ui` can reference `agentstack-server-audience` at create time.
  (4) **Seed user password**: generate-if-absent via python3 `secrets` module →
  write to OpenBao KV → read back each run. Uses `openbao_provisioner_token`
  (set by `openbao_bootstrap`). Password update in `keycloak_user` will report
  `changed: true` each run (module limitation; value is stable from OpenBao).
  **Next step: run `ansible-playbook --syntax-check` and `ansible-lint` in VM,
  then `site.yml` end-to-end. Verify CA proof task passes with `validate_certs:
  true`; if not, fall back to `uri + ca_path` for affected steps only.**
- 2026-06-20 — **Phase 0 validated in VM.** `site.yml` (preflight only) ran green
  on a VM pre-provisioned with armory → syntax-check implicitly passes and the
  preflight readiness logic works against real armory resources. Phase 0 done for
  practical purposes. Remaining Phase 0 housekeeping is non-blocking and can ride
  alongside Phase 1: `AGENTS.md`, `teardown.yml` (naturally grows as
  Phase 1+ creates tear-downable state), `bringup-all`. **Next: Phase 1, starting
  with the module→internal-CA proof spike.**
- 2026-06-20 — **AgentStack Postgres: self-roll, not Bitnami (DECISION).** The
  chart's bundled `postgresql` is the Bitnami subchart
  (`oci://registry-1.docker.io/bitnamicharts` 16.x.x); Bitnami gutted its free
  catalog in 2025 (versioned images → best-effort `bitnamilegacy`, maintained
  images behind paid Bitnami Secure Images), and the chart maintainers already
  migrated `redis` off Bitnami → a supply-chain/maintenance risk. So set
  `postgresql.enabled: false` and self-roll a `postgres:16` StatefulSet copied
  from armory's keycloak role (official image, OpenBao/VSO creds, `pki-int` TLS
  already built), wired via the chart's `externalDatabase` block. Confirmed keys:
  `externalDatabase.{host,port:5432,user,database,password,existingSecret,
  ssl:true,sslRootCert}` — `existingSecret` (VSO delivery) + `ssl`/`sslRootCert`
  exist, which also **resolves the earlier "is client-side DB TLS expressible?"
  open question (yes)**. Scope check: other subcharts are NOT Bitnami
  (redis→cloudpirates, seaweedfs→official, phoenix→arize) so used as-is; `common`
  is bitnami library-only (build-time, low risk). Reqs doc deliberately NOT
  touched — it's the external-Keycloak spec; the app data tier is out of its
  scope. NB: if `phoenix.enabled`, check whether Phoenix drags in its own
  Bitnami-based DB — defer until/unless Phoenix is turned on.
- 2026-06-20 — **Audit posture decisions.** (1) garrison enables audit events on
  its own `agentstack` realm (login + admin events, `jboss-logging`); armory owns
  the listener transport + retention. (2) **OpenBao becomes the single source of
  truth for ALL secrets** (principle #4) — no chart default or chart auto-gen
  accepted; `nextauthSecret` now sourced from OpenBao too. This doubles as a
  discovery pass to surface/replace insecure chart defaults (Postgres
  `admin-password`, SeaweedFS `agentstack-admin-*`). Audit coverage we get for
  free: OpenBao audit device (every secret read + PKI issue, incl. VSO syncs and
  cert-manager issuance; armory file device, daily rotate, keep 7) + Keycloak
  events (auth + IdP-config changes). Residual gap stays the data plane
  (pgaudit/S3 access logs), a separate decision. Boundary: OpenBao audits up to
  the k8s Secret; pod-level secret reads need k3s audit (armory's).
- 2026-06-19 — Phase 0 execution chunk 1 completed in garrison repo:
      created Ansible scaffold (`.env.example`, `ansible/playbooks/site.yml`, dev
      inventory, `.ansible-lint`, `.yamllint`), added pinned `ansible/requirements.yml`
      (`kubernetes.core` + `community.general`), and implemented `ansible/roles/preflight`
      with module-based checks for required armory services/deployments using
      `kubernetes.core.k8s_info`. `ansible-playbook --syntax-check`/`ansible-lint`
      could not be executed on this host because `ansible-playbook` is not installed
      in the active Windows terminal; validation is deferred to the armory VM.
- 2026-06-19 — Phase 0 tightening pass: `ansible/requirements.yml` versions were
      intentionally unpinned to test latest collections during development
      (explicit note added to file; pin before demo). `preflight` now distinguishes
      missing deployments from present-but-not-ready deployments and fails readiness
      if a Deployment is scaled to 0, has `availableReplicas < spec.replicas`, or
      lacks an `Available=True` condition.
- 2026-06-22 — **F1 module→CA proof spike: armory PKI is NOT what the spec
  assumed (FINDING + DECISION).** Running the CA/HTTPS proof against the live VM
  showed armory now uses **two mutually-exclusive internal roots**, and the spec's
  "internal CA = `openbao-ca`" was wrong for Keycloak:
    - OpenBao API (`:8200`) is served by **`CN=OpenBao-Internal-CA`** (secret
      `openbao-ca`, ns `openbao`). Validates OpenBao only.
    - Keycloak (`:8443`) is served by **`CN=Armory Root CA`** → `CN=Armory
      Internal Issuing CA` (cert-manager `openbao-pki-internal` ClusterIssuer).
      `openbao-ca` does NOT validate it. The Armory Root CA has no dedicated CA
      secret; it is carried as the **`ca.crt` key on the `keycloak-internal-tls`
      secret** (ns `keycloak`). Verified by curl: each root gives HTTP 200 for its
      own service and fails (000) for the other.
  **DECISION (combined trust bundle):** `prepare_internal_https_caller.yml` now
  fetches BOTH CA secrets and concatenates them into one `internal_ca_bundle_path`
  (trusts either root). New var contract: `openbao_ca_{secret_name,namespace,
  cert_key}` + `cert_manager_ca_{secret_name,namespace,cert_key}` (Armory Root CA
  defaults to `keycloak-internal-tls`/`keycloak`/`ca.crt`, configurable). Verified
  the combined bundle validates both endpoints (200/200).
  **DEVIATION from module-first (resolves the 2026-06-18 Phase-1 caveat):** the
  keycloak modules do NOT accept the internal CA over 8443 —
  `community.general.keycloak_realm_info` has no `ca_path`, and `open_url` ignores
  `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` (→ `CERTIFICATE_VERIFY_FAILED`). So the
  master-realm proof uses **`ansible.builtin.uri` + `ca_path`** (read-only
  `GET /realms/master`). `uri`+`ca_path` is therefore REQUIRED for in-cluster
  Keycloak calls, not merely a per-step fallback. Reqs §4.2/§4.3/§6 corrected.
- 2026-06-22 — **F3 done: `teardown.yml` re-pointed at the contract + validated
  live.** Garrison-only scope confirmed (no armory state touched). Fixes:
    - **KV cleanup was wrong, now correct.** Old code did a single `DELETE` on
      `secret/data/garrison` (soft-deletes one secret literally named `garrison`,
      leaves versions/metadata). Replaced with `common/tasks/purge_openbao_kv_
      prefix.yml`: LIST `secret/metadata/garrison/` → `DELETE
      metadata/garrison/<key>` per entry (purges all versions). Flat layout
      assumed; nested folders are surfaced via a non-fatal warning, not silently
      skipped. Validated: seeded `test-a`/`test-b`, ran teardown, list returns 404.
    - **`include_tasks` does NOT load a role's `defaults/`.** Teardown pulled the
      vendored `common` helpers via `include_tasks`, so common-defaults-only vars
      (`openbao_provisioner_policy_name`, `openbao_provisioner_token_ttl`,
      `keycloak_bootstrap_admin_*`) were undefined at runtime. Switched the three
      `prepare_*` includes to `include_role` + `tasks_from` (loads `common`
      defaults; `group_vars` still overrides). This was the bulk of the "~13
      undefined vars."
    - **Admin-cred key mismatch.** `prepare_keycloak_bootstrap_admin.yml` keyed on
      `admin-username`/`admin-password`; the real `keycloak-bootstrap-admin`
      secret keys are `username`/`password` (verified). Corrected the defaults.
    - **Jinja gotcha:** `_list.json.data.keys` resolved to the dict `.keys`
      *method*, not the JSON `"keys"` field → `reject` failed. Fixed with
      subscript `data['keys']`.
    - Removed the dead `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE` env block on the realm
      delete (open_url ignores it; `keycloak_realm` honours the real `ca_path:`).
  **Latent issue flagged (not fixed here):** garrison has *duplicate, divergent*
  provisioner-policy and admin-cred logic — `openbao_bootstrap` (inline,
  `garrison_provisioner_policy_name`) vs vendored `common/prepare_openbao_
  provisioner_token.yml` (`openbao_provisioner_policy_name`); and
  `load_keycloak_admin_creds.yml` vs `prepare_keycloak_bootstrap_admin.yml`. Both
  pairs create/read the SAME live names with different defaults/capsets, guarded
  by create-if-absent → order-dependent. Works today because site.yml seeds the
  policy first; should be consolidated.
- 2026-06-22 — **Phase 2 STARTED (scaffolding complete).** Built the full
  `agentstack_secrets` role (Phase 2: Secrets + trust). Structure:
    - `defaults/main.yml` — 50+ parameterized vars for OpenBao paths, VSO resources,
      trust bundles, secret names.
    - `tasks/main.yml` — Orchestrator (5 subtasks in sequence).
    - `tasks/secret_inventory.yml` — Read-only discovery pass; outputs table of
      ALL chart secrets (OIDC, Postgres, Redis, SeaweedFS, encryptionKey,
      auth.nextauthSecret) + defaults + delivery methods per §4.5 of reqs.
    - `tasks/oidc_client_secrets.yml` — Generate-if-absent OIDC client secrets
      in OpenBao KV, update Keycloak clients (via REST, not module — modules don't
      support internal CA per Phase 1 caveat), apply VSO
      VaultConnection/VaultAuth/VaultStaticSecret, wait for sync, verify Secret keys.
    - `tasks/postgres_secrets.yml` — Generate-if-absent Postgres creds + write to
      OpenBao, apply VSO VaultStaticSecret, apply cert-manager Certificate (pki-int
      TLS for DB service FQDN), wait for both syncs + cert issuance.
    - `tasks/other_secrets.yml` — Generate-if-absent hookless secrets
      (encryptionKey, auth.nextauthSecret) + Redis + SeaweedFS, store in OpenBao,
      cache facts for Phase 3 Helm injection (not VSO — no existingSecret hooks).
    - `tasks/trust_bundles.yml` — Apply trust-manager Bundles (pki-int +
      pki-ext) to distribute CAs into agentstack namespace for runtime OIDC +
      provisioning trust paths.
    - `templates/*.yaml.j2` — Jinja CRD templates for VaultConnection, VaultAuth,
      VaultStaticSecret (OIDC + Postgres), Certificate, Bundles.
    - `README.md` — 300-line implementation guide (pattern + vars + inventory
      table + testing + known limitations + Phase 3 integration).
  - **Key decisions baked into Phase 2:**
    (1) **REST-only Keycloak client updates** (uri, not keycloak_client module).
        Modules use `open_url` which ignores SSL_CERT_FILE/REQUESTS_CA_BUNDLE.
        Fix: use uri + ca_path. DEVIATION from module-first, but only for this
        step; VSO resources use modules normally.
    (2) **Hookless secrets as Helm facts, not VSO Secrets** (encryptionKey,
        auth.nextauthSecret per §4.5). These have no existingSecret hook; syncing
        would lose them (chart ignores synced Secrets; only values are rendered).
        Solution: OpenBao→read→fact→Phase 3 --set.
    (3) **Conditional secrets (Redis, SeaweedFS)** generated but VSO resources
        NOT applied here. Phase 3 must check redis.enabled / seaweedfs.enabled
        before consuming. If disabled, OpenBao KV paths are harmless orphans.
    (4) **cert-manager Certificate for Postgres** uses openbao-pki-internal
        ClusterIssuer (per Phase 3 self-rolled DB pattern), SAN = DB service
        FQDN. Paired with postgres:16 StatefulSet (Phase 3, agentstack_db role).
  - **Not yet done (Phase 2 substeps):**
    - [ ] Syntax-check + ansible-lint on VM (deferred to VM validation in Phase 4)
    - [ ] Verify secret generation + OpenBao storage + VSO sync on live VM
    - [ ] Confirm Keycloak client secret update via REST (verify access token auth
          flow works)
    - [ ] Validate fact caching across playbook runs (ansible-inventory check)
    - [ ] Test teardown.yml cleanup of Phase 2 secrets from OpenBao KV
  **Next: VM validation of Phase 2 role (full playbook run).**
- 2026-06-22 — **Phase 2 REVIEWED, REWORKED & VALIDATED (supersedes the STARTED
  note above).** Review found the role substantially broken — design-level, not
  param typos — concentrated in the VSO/trust/CA integration (the parts needing
  armory's real topology, which Copilot couldn't probe). Each fix validated live
  on the VM, one at a time, until the full `site.yml` ran `failed=0`. Fixes:
    1. **Undefined `agentstack_vso_sa_name`** — a botched edit merged two
       defaults lines into a comment; the VaultAuth template referenced the
       now-undefined var. `garrison_vso_sa_name` (openbao_bootstrap default) is
       also out of scope in this role → defined `agentstack_vso_sa_name:
       agentstack-vso` as a literal (must match the k8s-auth binding).
    2. **VaultConnection CA was wrong + wrong shape.** Referenced a nonexistent
       `openbao-ca` secret in the agentstack ns. VSO needs the OpenBao *listener*
       CA (CN=OpenBao-Internal-CA) there. Also `caCertSecretRef` is a STRING
       (secret name), not an object. Fixed both.
    3. **Trust bundles sourced from the wrong namespace.** trust-manager runs
       `--trust-namespace=openbao` and reads ALL secret sources from `openbao`
       only (source namespace is ignored). Copilot sourced `keycloak-internal-tls`
       (keycloak ns) and `armory-tls` (claimed ingress-nginx; actually keycloak).
       Repointed to openbao-ns sources: `openbao-ca` (→ VSO CA bundle
       `agentstack-openbao-ca`) and `openbao-ui-tls` ca.crt = Armory Root CA (→
       public CA bundle `agentstack-public-ca` for pod OIDC, Phase 3).
    4. **OIDC secret data model was incoherent.** Two separate KV leaves each
       under key `client_secret`, but the VaultStaticSecret pointed at the folder
       and expected uiClientSecret/serverClientSecret in one Secret. Consolidated
       to ONE KV leaf with both keys; VSS points at the leaf.
    5. **Keycloak client update could wipe Phase 1 config** — PUT with a
       `{secret}`-only body. Changed to GET-modify-PUT (full client rep + merged
       secret), preserving redirectUris/flows/default-scopes.
    6. **Dict-key templating** — Ansible does not template task-arg dict *keys*;
       the OIDC KV write stored literal `{{ agentstack_ui_client_secret_key }}`
       as the key. Built the `data` dict inside one Jinja expression so the
       variables resolve as keys.
    7. **No kubeconfig** — the role's `kubernetes.core.*` tasks passed no
       `kubeconfig:` and none was in env → "Invalid kube-config". Added play-level
       `environment: K8S_AUTH_KUBECONFIG` in site.yml (explicit per-task kubeconfig
       still overrides).
    8. **Flattened all Phase 2 KV keys** to `garrison/agentstack-*` (were
       `garrison/agentstack/*`, a nested folder the flat F3 teardown purge would
       orphan — same fix as Phase 1's seed-admin key). Reordered main.yml so the
       namespace + VSO SA + OpenBao CA bundle exist before the VSO resources.
  **Validated end state (live):** VaultConnection + VaultAuth HEALTHY/READY; both
  VaultStaticSecrets SYNCED (agentstack-oidc-client-secrets {uiClientSecret,
  serverClientSecret}; agentstack-postgres-credentials {username,password,
  postgres}); Postgres TLS cert issued; trust bundles synced; KV flat. Full
  `site.yml` → `failed=0`.
  **Minor leftovers (non-blocking):** (a) `secret_inventory.yml`'s PRINTED table
  still describes the old/wrong trust sourcing (keycloak-internal-tls,
  armory-tls/ingress-nginx) — cosmetic but misleading; (b) VSO adds a `_raw`
  full-JSON key to synced secrets (harmless; suppress with `excludeRaw: true` if
  desired); (c) the two Keycloak client-secret PUTs are `changed_when: true` every
  run (Keycloak hashes aren't diffable) — idempotent in value, noisy in `changed`.
- Open input still needed before Phase 3: the concrete `<armory-domain>` /
  public Keycloak host string for the issuer URL + UI host.
- 2026-06-22 — **Phase 3 SCAFFOLDING COMPLETE (ready for VM validation).** Built
  the full `agentstack_db` and `agentstack` roles with module-first + idempotency
  by design. Roles structure:
  **`agentstack_db` (self-rolled Postgres):**
    - `defaults/main.yml` — Variables for Postgres 16 StatefulSet: image, storage,
      TLS cert secret, credentials secret, CA bundle names.
    - `templates/postgres.yaml.j2` — Service + StatefulSet manifests copied from
      armory's keycloak pattern: official postgres:16 image, VSO-provided creds,
      optional pki-int TLS (ssl=on), readiness/liveness probes, resource limits.
    - `tasks/main.yml` — Uses `kubernetes.core.k8s` to apply templated manifests,
      waits for StatefulSet readiness (1 replica ready), verifies `pg_isready`
      connection. All reads have `changed_when: false` for idempotency.
  **`agentstack` (Helm release + hostAlias + ingress):**
    - `defaults/main.yml` — 50+ parameterized vars: chart repo/name/version,
      external DB FQDN + port, OIDC issuer URL, UI host, secret names, Helm values
      (keycloak.enabled/postgresql.enabled: false, externalDatabase, externalOidcProvider,
      auth.validateAudience: true, auth.basic.enabled: false, trustProxyHeaders: true).
    - `tasks/main.yml` — Orchestrator including 5 subtasks in sequence.
    - `tasks/helm_repository.yml` — Uses `kubernetes.core.helm_repository` to add
      the stack.ai chart repo (idempotent).
    - `tasks/helm_release.yml` — Uses `kubernetes.core.helm` to deploy the release
      with full `values:` (keycloak disabled, postgresql disabled, external DB/OIDC).
      Ensures namespace exists first, waits for release ready (10m timeout).
    - `tasks/ui_ingress.yml` — Creates cert-manager `Certificate` for UI ingress TLS
      (SAN = agentstack-ui-host, issuer = openbao-pki-external), waits for Ready.
    - `tasks/hostaliases_patch.yml` — Discovers ingress-nginx Service ClusterIP,
      patches UI + server Deployments with `hostAliases` mapping armory-domain →
      ClusterIP (for in-cluster Keycloak resolution). Uses `kubernetes.core.k8s_info`
      + `state: patched` (module-based, not kubectl patch).
    - `tasks/readiness_check.yml` — Waits for UI + server Deployments to reach
      ready replicas (30 retries × 10s = 5m timeout per deployment).
  **Key design decisions baked into Phase 3:**
    (1) **Module-first throughout.** `kubernetes.core.helm_repository`, `helm`,
        `k8s` (templated), `k8s_info`, `k8s_exec` — no `command: helm`, no
        `kubectl apply`, no `kubectl patch`. Result: full idempotency + accurate
        `changed` reporting.
    (2) **Helm values fully defined in defaults.** All values (externalDatabase,
        externalOidcProvider, auth, ingress) derived from role vars, so the release
        is idempotent across re-runs: same values → no helm diff → `changed: false`.
    (3) **Secrets come from Phase 2.** OIDC secrets (VSO `agentstack-oidc-client-secrets`),
        Postgres creds (VSO `agentstack-postgres-credentials`), and CA bundles (trust-manager
        `agentstack-public-ca`) are assumed present; the role does NOT create them —
        it references them as already-synced by Phase 2.
    (4) **hostAlias patch pattern from armory, but module-based.** Discovers the
        ingress-nginx ClusterIP dynamically (no hardcoding), patches Deployments with
        strategic merge (preserves existing hostAliases, adds new entry).
    (5) **TLS for Postgres enabled by default** (`agentstack_pg_tls_enabled: true`).
        The cert-manager Certificate is created in Phase 2; the StatefulSet mounts it.
  **Updated `site.yml`:** Added `agentstack_db` and `agentstack` roles to the play
  with tags `agentstack_deploy`. Role execution order: Phase 2 (agentstack_secrets)
  completes → Phase 3 (agentstack_db + agentstack) runs sequentially.
  **Known unknowns for Phase 4 (runtime verification):**
    - Concrete `<armory-domain>` value still needed in `.env` (e.g. `armory.local` or
      `armory.example.com`); defaults to `armory.local` in role vars.
    - Whether the `externalDatabase.{host,port,user,database,ssl,sslRootCert}` values
      and VSO Secret keys match the chart's expectations (to be verified in VM).
    - Whether `auth.validateAudience: true` works correctly with the audience mapper
      from Phase 1 (scope `agentstack-server-audience` → `aud` claim).
    - Browser E2E login + token decode (Phase 4).
    - ROPC (`directAccessGrantsEnabled`) necessity (Phase 4).
  **Next: VM validation.** Run `ansible-playbook --syntax-check` and `ansible-lint`
  on the updated `site.yml`, then full `site.yml` end-to-end. Verify: (1) Postgres
  StatefulSet ready + accepting connections; (2) Helm release deployed + UI/server
  Deployments ready; (3) hostAliases patched correctly; (4) UI cert issued; (5)
  ingress resolves to the UI service. Then proceed to Phase 4 (browser login E2E).
- 2026-06-22 — **Phase 3 REVIEWED, REWORKED & VALIDATED against the real chart
  (supersedes the SCAFFOLDING note above).** Copilot's scaffolding was clean Ansible
  but built on a **fabricated chart source + invented values schema**, and dropped
  the two required secrets. Reverse-engineered the authoritative contract from
  armory's deleted `beeai_agentstack_tofu` role (git `083b771^`) and from
  `helm show values`/`helm template` of the **real chart pulled in the VM**. Fixes:
  - **Chart source (was fabricated).** `charts.stack.ai`/repo `stack` is an
    unrelated product. Real chart is an **OCI artifact**:
    `oci://ghcr.io/i-am-bee/agentstack/chart/agentstack`. OCI needs no `helm repo
    add` → **deleted `helm_repository.yml`** and pass the `oci://` URL straight to
    `kubernetes.core.helm` `chart_ref`. **Registry latest is 0.7.1, not 0.7.2**
    (0.7.2 is the unreleased main appVersion and 404s on pull) — pinned `0.7.1`;
    its external-OIDC values are byte-identical to the spec's quoted 0.7.2.
  - **Two REQUIRED hookless secrets were dropped.** `encryptionKey` (top-level) +
    `auth.nextauthSecret` are now injected in `helm_release.yml` from the Phase 2
    facts `agentstack_helm_encryption_key` / `agentstack_helm_nextauth_secret`
    (via `combine(..., recursive=True)`). Without these the app is silently broken
    (empty encryptionKey → empty secret).
  - **DB URL contract (only discoverable by rendering).** With
    `externalDatabase.existingSecret` set, the chart reads `PERSISTENCE__DB_URL`
    from a secret key named **`sqlConnection`** — it does NOT assemble the URL from
    host/user/password. Phase 2's secret had only `username/password/postgres`.
    **Fixed in Phase 2** (`postgres_secrets.yml`): write a pre-built
    `postgresql+asyncpg://user:pass@host:port/db` URL as a `sqlConnection` KV key
    (VSO syncs it verbatim into `agentstack-postgres-credentials`); the wait/assert
    now require that key. Password stays out of Helm values (honors §6 VSO intent).
  - **Service-name mismatch.** Copilot's db role named the Service `postgres`, but
    Phase 2's TLS cert SAN + FQDN expect **`agentstack-postgresql`**. Aligned the
    db role Service/StatefulSet, the agentstack role `agentstack_db_host`, and the
    `sqlConnection` host all to `agentstack-postgresql.<ns>.svc.cluster.local`
    (matches the cert SAN → verify-full possible). Also fixed the db role's TLS
    secret ref `agentstack-postgres-tls` → live name **`agentstack-postgresql-tls`**.
  - **Dual-issuer patch was incomplete.** Copilot patched hostAliases only. The
    pods also need the **private CA mounted in-pod + `NODE_EXTRA_CA_CERTS`** to
    validate the Armory-Root-CA HTTPS issuer (armory's proven pattern). Rewrote
    `hostaliases_patch.yml` to patch BOTH Deployments (verified container names:
    UI deploy `agentstack-ui`→container `agentstack-ui`; server deploy
    `agentstack-server`→container **`agentstack`**) with hostAlias (issuer + UI
    hosts → ingress ClusterIP) + CA volume/mount + trust env. Ingress Service name
    fixed `ingress-nginx` → **`ingress-nginx-controller`** (verified live).
  - **Deadlock fix.** Helm ran `wait: true`, but pods can't go Ready until the
    hostAlias/CA patch (a later task) lands → 10-min timeout then fail. Changed to
    `wait: false`; readiness is gated afterward in `readiness_check.yml` (no bundled
    keycloak hook in external mode, so one pass + patch + wait converges).
  - **Honesty/schema cleanups.** Removed bogus `auth.method: oidc` (not a chart
    key — OIDC-only is `auth.basic.enabled: false`); set `auth.nextauthUrl`/`apiUrl`
    to the public UI URL (chart default is localhost); dropped unconfirmed
    `externalDatabase.type`/`existingSecretPasswordKey`; `sslRootCert` is an inline
    PEM not a path (left empty = sslmode=require); removed `changed_when: false`
    from the mutating helm/Certificate/StatefulSet applies (first install now
    reports `changed`, not `ok`).
  **Validated:** `--syntax-check` passes; `helm template` with garrison's full value
  set renders cleanly (schema accepted), confirming externalDatabase/externalOidcProvider/
  auth/ingress keys and the rendered server env (`AUTH__OIDC__ISSUER`,
  `PERSISTENCE__DB_URL`←sqlConnection, `AUTH__OIDC__VALIDATE_AUDIENCE=true`,
  `AUTH__BASIC__ENABLED=false`). Reworked tree synced to `/opt`.
  **Not yet runtime-tested (Phase 4 / next bringup):** a live `site.yml` run; the
  Python server's CA trust may need `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE` in
  addition to `NODE_EXTRA_CA_CERTS` (flagged in the patch); browser E2E login.

- 2026-06-22/23 — **Phase 3 LIVE-VALIDATION COMPLETE (all runtime bugs fixed).**
  Full `site.yml` ran end-to-end after resolving a chain of runtime bugs. Each was
  found on a live bringup iteration and fixed in-place in the roles. In order:
  1. **`role 'common' was not found`** — `.env` sourced without `set -a`; env vars
     not exported to `ansible-playbook` child. Fix: `set -a; source ../.env; set +a`.
     `bringup-all.sh` does this automatically; only bites on direct playbook runs.
  2. **`Invalid kube-config file. No configuration found`** — Copilot's Phase 3 tasks
     passed `kubeconfig: "{{ lookup('env', 'K8S_AUTH_KUBECONFIG') }}"` explicitly;
     `lookup` runs in controller env (Windows/WSL2) where the var is unset. Fix:
     remove all explicit `kubeconfig:` params from tasks; rely on the play-level
     `environment: K8S_AUTH_KUBECONFIG` set in `site.yml`.
  3. **Broken YAML after kubeconfig removal** — the removed `kubeconfig:` key was
     the first key on the module line; removing it joined the module name inline with
     the next key (e.g., `kubernetes.core.k8s:        state: present`). Fix: manual
     YAML repair for affected tasks.
  4. **`k8s_exec` crash — `invalid literal for int()`** — `pg_isready` exec task
     parsed the pod Ready status incorrectly and was redundant (readiness probe IS
     pg_isready; `readyReplicas == 1` already proves DB is up). Fix: remove the exec
     task entirely.
  5. **`sqlConnectionSuperuser` missing from secret** — `create-pgvector-extension`
     init container reads this key; Phase 2 only wrote `username/password/postgres/
     sqlConnection`. Fix: add `sqlConnectionSuperuser` to the Postgres KV write (same
     URL as `sqlConnection` — our user is superuser).
  6. **`pgvector/pgvector:pg16` required, not `postgres:16`** — the chart's
     `create-pgvector-extension` init container runs `CREATE EXTENSION vector`; the
     official `postgres:16` image has no pgvector. Fix: change db role default image
     to `pgvector/pgvector:pg16`.
  7. **VSO serves stale KV (1h `refreshAfter`)** — on re-runs, VSO didn't see the new
     `sqlConnectionSuperuser` key for up to an hour. Fix: after each `VaultStaticSecret`
     apply, patch `vso.hashicorp.com/force-sync: "{{ ansible_facts['date_time'].iso8601_micro }}"`.
     Also fixed an `ansible_date_time` deprecation warning (use `ansible_facts['date_time']`).
  8. **Server crashloops: `load_verify_locations … cannot be all omitted`** — with
     `DB_USE_SSL=true` the app calls `load_verify_locations(cafile=db_ssl_cert)`;
     empty `sslRootCert` → crash. Fix: read `ca.crt` from `agentstack-postgresql-tls`
     secret in `helm_release.yml`, inject as `externalDatabase.sslRootCert` (inline
     PEM string, not a file path) via `combine(..., recursive=True)`.
  9. **502 Bad Gateway post-login** — nginx `upstream sent too big header`; the NextAuth
     JWE session cookie is too large for the default 4k/8k proxy buffers. Fix: ingress
     annotations `proxy-buffer-size: 64k`, `proxy-buffers-number: 8`.
  10. **401 `CERTIFICATE_VERIFY_FAILED`** — Python server can't verify the Keycloak
      issuer TLS; `NODE_EXTRA_CA_CERTS` is Node-only and was the only CA env var set.
      Fix: add `SSL_CERT_FILE` + `REQUESTS_CA_BUNDLE` pointing to the mounted CA
      bundle on the **main container only** (NOT init containers — they don't mount
      the CA volume; adding to init containers broke the `create-buckets` S3 client).
  11. **401 `Missing 'sub' claim`** — Keycloak 24+ moved the `sub` mapper into the
      built-in `basic` client scope, which was absent from `agentstack_ui_default_client_scopes`.
      Fix: add `basic` + `acr` to the defaults list.
  12. **401 `Invalid claim 'aud'`** — the server (0.7.1) builds `expected_aud` from
      `create_resource_uri(request.url.replace(path="/"))` — a URL like
      `https://agentstack.armory.local/` — NOT the `serverClientId` string. Token
      carries `aud=['agentstack-server','account']`; these never match. Fix:
      `auth.validateAudience: false` in Helm values. The audience mapper is kept
      (correct per spec intent) but the URL-based check is disabled. Safer than
      guessing the exact URL the server expects; iss/sub/exp/sig are still validated.
  13. **500 `value is not a valid email address`** — seed admin email was
      `agentstack-admin@localhost`; the agentstack server's user-sync rejects
      non-routable TLDs. Fix: `agentstack_seed_admin_email: "admin@armory.dev"`.
  **Teardown fix (2026-06-22):** `keycloak_realm state: absent` used `ca_path:`
  which `open_url` (used by the module) does not accept → `Unsupported parameters`.
  Fix: install CA to OS trust store before the realm-delete task (same as the
  bringup ca_proof pattern); remove `ca_path` from the task.
  **Admin credentials surfaced (2026-06-22):** added `admin_credentials.yml` to
  Phase 2 (`agentstack_secrets`) — syncs the seed-admin `username`+`password` from
  OpenBao KV via VSO into a `agentstack-admin-credentials` k8s Secret in the
  `agentstack` namespace (same pattern as armory; README has the retrieval command).

- 2026-06-23 — **Phase 4 PARTIAL: browser E2E validated; CLI login pending.**
  **Validated:** full browser login flow confirmed working (OIDC redirect → Keycloak
  authenticate → session cookie → UI loads → API requests succeed). JWE session
  cookie decrypted and confirmed: `accessToken` typ=Bearer, `aud=['agentstack-server',
  'account']`, iat fresh (post-fix), forwarded by the UI as Authorization Bearer to
  the API. API returns 200 on `GET /api/v1/providers`.
  **Remaining Phase 4 gate — beeai CLI login:**
  The beeai CLI is the only way to determine whether ROPC (`directAccessGrantsEnabled`)
  is needed. Both clients currently have it disabled (per spec §3.2 / DECISION
  2026-06-20). Test procedure:
  ```
  # On the VM (pip-installed or via the agentstack project):
  pip install beeai          # or however the CLI ships with 0.7.1
  beeai connect https://agentstack.armory.local
  # -- or --
  beeai login https://agentstack.armory.local
  ```
  Expected outcomes:
  - **Device flow / browser redirect** → no ROPC needed; record `directAccessGrantsEnabled`
    stays `false` for both clients. Close this item.
  - **Prompts username + password (ROPC)** → enable on `agentstack-ui` client
    (`direct_access_grants_enabled: true` in `clients.yml`), re-test, record finding.
  - **CLI doesn't exist / ships differently in 0.7.1** → document the gap; may be
    a post-0.7.x feature.
  Note: do NOT enable ROPC on `agentstack-server` for CLI use — the server client is
  M2M only. ROPC for human CLI login belongs on `agentstack-ui` (confidential, standard
  flow enabled = accepts password grant in addition to code flow).

