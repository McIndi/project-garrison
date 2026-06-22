# 001 — Deploy Agent Stack against armory's external Keycloak

**Status:** open · **Created:** 2026-06-18

## Goal

Stand up `project-garrison` as an Ansible repo that deploys the BeeAI / Agent
Stack Helm chart (`agentstack` 0.7.2) with its bundled Keycloak **disabled**,
pointed at the external Keycloak owned by `project-armory`. "Done" = a user can
log into the Agent Stack UI via OIDC against the `agentstack` realm, and the
server accepts the token (no 401) end-to-end.

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
| AgentStack Postgres | **`postgresql.enabled: false`; self-roll `postgres:16` StatefulSet via armory's pattern, wire via `externalDatabase`** | DECISION 2026-06-20 — avoid Bitnami subchart (see Notes) |

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
  agentstack_db/         # self-rolled postgres:16 StatefulSet (armory pattern) + pki-int TLS; NOT the Bitnami subchart
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
- [ ] `teardown.yml` playbook (garrison's analog of armory's
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
- [ ] **First, prove the module→internal-CA path** (the principle #3 caveat):
      one `community.general.keycloak_realm` call against
      `https://keycloak-service.keycloak.svc.cluster.local:8443` with the pki-int
      CA bundle. If it can't present the CA, decide fallback (REST `uri`) for
      *that step only* before building the rest.
- [ ] Readiness assertion (write failing first): `keycloak_realm` /
      `k8s_info` confirms realm `agentstack` exists.
- [ ] Realm `agentstack`: bootstrap via `KeycloakRealmImport` CR applied with
      `kubernetes.core.k8s` (NO `clientScopes` block — it suppresses built-in
      scopes and breaks sign-in; see realmimport.yaml.j2 warning), OR via
      `community.general.keycloak_realm`. Include seed admin user.
- [ ] Both clients via `community.general.keycloak_client` (idempotent, no
      manual GET→PUT):
      - `agentstack-ui`: confidential, `standardFlowEnabled: true`,
        `directAccessGrantsEnabled: false`, redirect/web-origins scoped to the
        **real** UI host (not the chart's `["*"]`).
      - `agentstack-server`: confidential, `standardFlowEnabled: false`,
        `serviceAccountsEnabled: true`, `directAccessGrantsEnabled: false`.
- [ ] Client scope `agentstack-server-audience` via
      `community.general.keycloak_clientscope` with an `oidc-audience-mapper`
      protocol mapper, `included.custom.audience: agentstack-server` (**literal
      client id, NOT a URL** — the §3.4 bug), `access.token.claim: "true"`,
      `id.token.claim: "false"`; assign as a **default** scope on `agentstack-ui`
      (via `keycloak_client` `default_client_scopes` / the clientscope module —
      verify which exposes default-scope assignment in the pinned version).
- [ ] Realm roles `agentstack-admin` + `agentstack-developer` via
      `community.general.keycloak_role`/`keycloak_realm_role`; assign
      `agentstack-admin` to the seed user (`keycloak_realm_rolemapping` /
      `keycloak_user`).
- [ ] **Enable audit events on the `agentstack` realm** (garrison owns this realm;
      armory owns only the listener/retention pipe — DECISION 2026-06-20). Set
      `eventsEnabled: true`, keep `jboss-logging` in `eventsListeners`,
      `adminEventsEnabled: true`, `adminEventsDetailsEnabled: true`, and an
      `eventsExpiration` — via `community.general.keycloak_realm`
      (`events_enabled`/`events_listeners`/`admin_events_enabled`/
      `admin_events_details_enabled`). Gives login + provisioning audit for the
      app layer (see Notes 2026-06-20).

### Phase 2 — Secrets + trust `agentstack_secrets` (~½ day)
- [ ] **Secret inventory & default-hardening (discovery — do this FIRST).**
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
- [ ] Generate-if-absent the two client secrets (never re-randomize on re-run),
      write to OpenBao KV; `VaultStaticSecret` + `Bundle` CRs applied with
      `kubernetes.core.k8s` (templated `definition`). Resulting k8s Secret in
      `agentstack` ns must carry keys **exactly** `uiClientSecret` /
      `serverClientSecret` (reqs §2, §7 confirmed).
- [ ] Generate-if-absent and deliver every other inventoried secret per its
      classification: `existingSecret`-capable ones (Postgres, Redis, …) via VSO
      `VaultStaticSecret`; hookless ones (`encryptionKey`, `auth.nextauthSecret`)
      read from OpenBao and injected as Helm values at deploy time.
- [ ] trust-manager `Bundle`s into `agentstack` ns: `pki-int` (admin API),
      `pki-ext` (OIDC validation over public URL).
- [ ] **AgentStack Postgres creds + TLS cert** (feeds `agentstack_db`):
      generate-if-absent DB user/password in OpenBao KV → VSO `VaultStaticSecret`
      → k8s Secret (keys the chart's `externalDatabase.existingSecret` expects);
      cert-manager `Certificate` from `openbao-pki-internal` (SAN = the DB service
      FQDN in `agentstack` ns) for `ssl=on`. Both copied from armory's keycloak
      role (`vaultstaticsecret.yaml.j2`, the `keycloak_pg_tls_*` Certificate).
- [ ] `encryptionKey` specifically: generate-if-absent in OpenBao, **inject as a
      Helm value at deploy time** (NOT a synced Secret — no `existingSecret` hook,
      fails silently when empty; reqs §4.5). `auth.nextauthSecret` is delivered
      the same way (OpenBao → Helm value), **not** left to chart auto-gen — so it
      gains audit provenance like everything else.

### Phase 3 — Deploy `agentstack` (~1 day)
- [ ] **`agentstack_db`: self-rolled Postgres (before the Helm release).** Apply
      the `postgres:16` Service + StatefulSet (copied from armory
      `keycloak/templates/postgres.yaml.j2`) into `agentstack` ns via
      `kubernetes.core.k8s`, consuming the OpenBao/VSO DB Secret + `pki-int`
      Certificate from Phase 2; run with `ssl=on`. This replaces the disabled
      Bitnami subchart.
- [ ] `kubernetes.core.helm` release (with `kubernetes.core.helm_repository` for
      the chart repo) using `values:`/`values_files:` — `keycloak.enabled: false`,
      **`postgresql.enabled: false`** + `externalDatabase.{host,port,user,database,
      existingSecret,ssl: true,sslRootCert}` pointed at the self-rolled DB
      (host = DB service FQDN; `sslRootCert` = the `pki-int` CA from the
      trust-manager Bundle),
      `externalOidcProvider.{issuerUrl,uiClientId,serverClientId,existingSecret}`,
      `auth.validateAudience: true`, `auth.basic.enabled: false` (OIDC-only),
      `trustProxyHeaders: true`. Leave `AUTH__OIDC__INSECURE_TRANSPORT` default
      (issuer is HTTPS). Do **not** patch Deployments for proxy env (chart-native
      in 0.7.2, reqs §4.4).
- [ ] hostAlias patch on UI + server Deployments mapping `<armory-host>` →
      ingress-nginx ClusterIP, via `kubernetes.core.k8s` (`state: patched`,
      strategic merge) — get the ClusterIP with `kubernetes.core.k8s_info`, not
      `kubectl get -o jsonpath`. (Logic from `headlamp/tasks/deploy.yml`
      296–333, but module-based.)
- [ ] UI ingress: `ingressClassName: nginx`, TLS cert from
      `openbao-pki-external` ClusterIssuer, SAN = UI host; keep host consistent
      with `agentstack-ui` redirectUris/webOrigins + cert SAN.

### Phase 4 — Runtime verification (~½ day)  ← retires §3.2 ROPC unknown
- [ ] Browser login E2E against the UI ingress; confirm redirect → token → app.
- [ ] Decode the **access** token; assert `aud` contains `agentstack-server` and
      the API returns 200 (not 401).
- [ ] Test the beeai CLI login. **This is the only way to learn** whether ROPC is
      actually needed on `agentstack-server`. If CLI login fails, flip
      `directAccessGrantsEnabled: true` and re-test; otherwise leave it off and
      record the finding here.
- [ ] `readiness_check`-style assertions wired into the playbook.

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
- Open input still needed before Phase 3: the concrete `<armory-domain>` /
  public Keycloak host string for the issuer URL + UI host.
