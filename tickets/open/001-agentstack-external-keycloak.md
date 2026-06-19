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
  agentstack/            # Helm release (external OIDC values) + hostAlias patch + UI ingress
```

The `common` role's `prepare_internal_https_caller.yml`,
`load_openbao_*_token.yml` task files are imported from armory's pattern (copy or
reference) — they encapsulate internal-CA acquisition for the HTTPS-only
(port 8443) Keycloak admin API (reqs §4.2, §6). The acquired CA bundle is what
the `community.general.keycloak_*` modules consume (`ca_path` /
`REQUESTS_CA_BUNDLE`), so this stays relevant even though we're not hand-rolling
REST.

Add a `requirements.yml` pinning `kubernetes.core` and `community.general`
(for the `keycloak_*` modules), installed in the VM via
`ansible-galaxy collection install -r requirements.yml`. Both Python deps
(`kubernetes`, `PyYAML`) must be present in the VM's Ansible interpreter.

## Tasks (phased to retire the two known unknowns early)

### Phase 0 — Scaffold (~½ day)  ← deploy-only, NO Vagrantfile/VM
- [ ] Clone armory's *conventions* into garrison: `.env.example` (incl. pointer
      to armory's kubeconfig), `common` task patterns, `ansible/playbooks/site.yml`,
      dev inventory, `.ansible-lint`, `.yamllint`. **Do NOT** add a `Vagrantfile`
      or VM-provisioning — garrison runs inside armory's VM.
- [ ] `preflight` role (replaces armory's heavyweight `env_guard`): assert armory
      is up before doing anything — kubeconfig valid, and via
      `kubernetes.core.k8s_info` confirm the Keycloak `Service`/CR, OpenBao,
      nginx-ingress, VSO, and trust-manager are present/Ready. Fail fast with a
      clear "run armory's site.yml first" message if not.
- [ ] Add `requirements.yml` pinning `kubernetes.core` + `community.general`;
      ensure `kubernetes`/`PyYAML` present in the VM's Ansible interpreter (these
      are already in armory's VM — verify, don't re-provision a VM).
- [ ] Fill in `CLAUDE.project.md` from `shared/templates/` — record the
      module-first + idempotency convention, the deploy-only/same-VM run model,
      AND the two-loop dev workflow cheat sheet (inner = redeploy garrison in
      place; outer = rebuild armory THEN re-run garrison; decision rule: "edited
      armory? outer. edited only garrison? inner"). Add garrison to the workspace
      Project Index.
- [ ] `teardown.yml` playbook (garrison's analog of armory's
      `teardown_k3s_workloads.yml`, gated by `-e teardown_confirm=true`): helm
      uninstall the release, delete the `agentstack` ns, `keycloak_realm:
      state=absent` for the `agentstack` realm, and clean garrison's OpenBao KV
      paths. This is what makes the inner loop `teardown.yml` → `site.yml` without
      touching armory.
- [ ] `bringup-all` convenience wrapper (script or Make target) documenting the
      forced outer-loop order: armory `site.yml` → garrison `site.yml` (since an
      armory rebuild wipes garrison's realm + KV state).
- [ ] Green `ansible-playbook --syntax-check` + `ansible-lint` before any logic.

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

### Phase 2 — Secrets + trust `agentstack_secrets` (~½ day)
- [ ] Generate-if-absent the two client secrets (never re-randomize on re-run),
      write to OpenBao KV; `VaultStaticSecret` + `Bundle` CRs applied with
      `kubernetes.core.k8s` (templated `definition`). Resulting k8s Secret in
      `agentstack` ns must carry keys **exactly** `uiClientSecret` /
      `serverClientSecret` (reqs §2, §7 confirmed).
- [ ] trust-manager `Bundle`s into `agentstack` ns: `pki-int` (admin API),
      `pki-ext` (OIDC validation over public URL).
- [ ] Generate-if-absent `encryptionKey`, store in OpenBao, **inject as a Helm
      value at deploy time** (NOT a synced Secret — no `existingSecret` hook,
      fails silently when empty; reqs §4.5). Sourcing it from OpenBao (vs
      regenerating) is what keeps the Helm release idempotent. Let chart own
      `auth.nextauthSecret`.

### Phase 3 — Deploy `agentstack` (~1 day)
- [ ] `kubernetes.core.helm` release (with `kubernetes.core.helm_repository` for
      the chart repo) using `values:`/`values_files:` — `keycloak.enabled: false`,
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
- Open input still needed before Phase 3: the concrete `<armory-domain>` /
  public Keycloak host string for the issuer URL + UI host.
