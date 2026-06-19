# Agent Stack + External Keycloak — Requirements for project-garrison

Status: **updated** (extraction complete as of current repo state; all §7 open
items resolved below against chart **agentstack 0.7.2**, appVersion 0.7.2).
Audience: whoever builds project-garrison to deploy the BeeAI/Agent Stack Helm
chart against an **external** Keycloak provided by project-armory.
Companion: [`keycloak-extraction-plan.md`](keycloak-extraction-plan.md) (armory side).

> **Chart version pin.** Every chart value, env var, helper, and provisioning
> behaviour quoted below was verified against `helm/Chart.yaml` **version 0.7.2**
> (`name: agentstack`, `appVersion: 0.7.2`). Re-verify §2, §3.4, §3.5, and §4.4
> if garrison targets a newer chart — these are the parts most likely to drift.

## 0. Current Armory State (updated)

The Keycloak extraction described in the companion doc is **complete**. Key facts
that change or refine what garrison must do:

- `beeai_agentstack_tofu` role has been **deleted** from armory. It does not
  exist in the repo. Anything it did that garrison needs is documented here.
- Armory runs a standalone **Keycloak Operator** deployment (`keycloak` role,
  `keycloak` namespace). The CR name is `keycloak`; the operator-created Service
  is `keycloak-service.keycloak.svc.cluster.local`.
- k3s API-server OIDC and Headlamp both now point at the `armory` realm
  (`k3s_oidc_issuer_url: .../realms/armory`, `headlamp_keycloak_realm: armory`).
  The `agentstack` realm does **not** exist in armory — it is entirely garrison's
  responsibility.
- The armory admin credential secret is `keycloak-bootstrap-admin` in the
  `keycloak` namespace, with keys `username` and `password`. Username value:
  `armory-admin`. This is the **master admin** for the master realm; garrison uses
  it to bootstrap the `agentstack` realm via the admin REST API.

## 1. Context

Agent Stack is moving out of project-armory into project-garrison. armory will
run a standalone Keycloak as a shared identity provider. Garrison will deploy
the Agent Stack chart with its bundled Keycloak **disabled**
(`keycloak.enabled: false`) and point it at armory's Keycloak via the chart's
`externalOidcProvider` settings.

The chart supports this mode. The catch: **in external mode the chart provisions
nothing in Keycloak** — it assumes a realm and pre-configured clients already
exist. Everything the bundled Keycloak used to set up automatically becomes
garrison's responsibility. This document enumerates that responsibility, plus
the in-cluster issuer/TLS engineering armory currently performs that garrison
will need to reproduce.

Values quoted below are verbatim from the chart
([`helm/values.yaml`](https://github.com/i-am-bee/beeai-platform/blob/main/helm/values.yaml),
[`helm/Chart.yaml`](https://github.com/i-am-bee/beeai-platform/blob/main/helm/Chart.yaml)).

## 2. The chart's external-OIDC contract

Setting `keycloak.enabled: false` activates `externalOidcProvider`:

```yaml
externalOidcProvider:
  issuerUrl: ""                       # OIDC issuer (realm) URL
  name: "OIDC"
  id: "oidc"
  rolesPath: "realm_access.roles"     # where roles are read from in the token
  uiClientId: "agentstack-ui"
  uiClientSecret: ""
  uiClientSecretKey: "uiClientSecret" # key within existingSecret
  serverClientId: "agentstack-server"
  serverClientSecret: ""
  serverClientSecretKey: "serverClientSecret"
  existingSecret: ""                  # secret holding the two client secrets
```

**Secret-key contract — CONFIRMED against 0.7.2.** The two key names garrison's
k8s Secret must use are fixed by the chart defaults `uiClientSecretKey:
"uiClientSecret"` and `serverClientSecretKey: "serverClientSecret"` (both quoted
above, unchanged in 0.7.2). Garrison's `existingSecret` must carry exactly those
two keys — or override the `*SecretKey` values to match whatever VSO produces.

Related flags that stay relevant in external mode (verbatim 0.7.2 defaults):

```yaml
trustProxyHeaders: false              # TOP-LEVEL key — drives TRUST_PROXY_HEADERS
                                      # on both UI and server containers (see §4.4)
auth:
  enabled: true
  basic:
    enabled: true                     # set false in garrison to force OIDC-only login
  validateAudience: true              # server validates aud == serverClientId
  nextauthSecret: ""
  nextauthUrl: "http://localhost:8334"
  nextauthDevUrl: ""
  apiUrl: "http://localhost:8333"
encryptionKey: ""                     # still required
```

Chart dependencies (none is Keycloak — confirms external mode is first-class):
`common`, `postgresql` (`postgresql.enabled`), `seaweedfs` (`seaweedfs.enabled`),
`phoenix-helm` (`phoenix.enabled`), `redis` (`redis.enabled`).

## 3. What the chart will NOT do in external mode

When `keycloak.enabled: false`, the chart does **not** create any of the
following. Garrison must provision them in armory's Keycloak (realm-import or
REST) before/with the Agent Stack release:

1. **The realm.** Create realm `agentstack` in armory's Keycloak.
   `externalOidcProvider.issuerUrl` must point at
   `https://<armory-host>/realms/agentstack`.
2. **The two clients.**
   - `agentstack-ui` — confidential, standard (authorization-code) flow; redirect
     URIs / web origins for the Agent Stack UI ingress host.
   - `agentstack-server` — the API/resource client; its client ID is the expected
     token audience.
   Client IDs must match `uiClientId` / `serverClientId`.
   > **Security note — `directAccessGrantsEnabled: true` on `agentstack-server`.**
   > The bundled 0.7.2 provisioner enables this, i.e. the **resource-owner password
   > credentials (ROPC) grant**, on the *resource* client. ROPC is generally
   > discouraged (it has the client handle raw user passwords). The reason it is on
   > is **not documented in the chart or manifests** — the likely driver is the
   > beeai CLI authenticating via password grant, but that is unconfirmed without
   > app-source/runtime verification. Garrison should **start with it disabled**
   > (`directAccessGrantsEnabled: false`) and only re-enable if CLI/automation
   > login actually breaks. Do not treat "safe to remove" or "required" as settled
   > — this one is **not knowable statically** and needs a runtime check.
3. **Client secrets.** Generate secrets for both clients, set them on the Keycloak
   clients, and seed them into a k8s Secret referenced by
   `externalOidcProvider.existingSecret` under keys `uiClientSecret` and
   `serverClientSecret`. Garrison should reuse the OpenBao + VSO pattern armory
   uses today for credential delivery (see §6).
4. **The audience mapping.** The server validates `aud: agentstack-server`
   (`auth.validateAudience: true`). Tokens issued to `agentstack-ui` must carry
   that audience. **CONFIRMED still wrong in the bundled 0.7.2 provisioner.** The
   bundled job (`helm/templates/keycloak/provision-job.yaml`) builds the audience
   mapper's `included.custom.audience` from a **URL** — it loops over an
   `AUDIENCES` array whose values are `$UI_URL` / `$API_URL` (i.e.
   `auth.nextauthUrl` / `auth.apiUrl`), **not** the literal client-id string. But
   the server validates `aud == AUTH__OIDC__CLIENT_ID == agentstack-server` (a
   bare client id, not a URL). That mismatch is exactly why armory's old bundled
   setup needed a post-install fixup. Garrison must bake the correct mapping in
   from the start:
   - a client scope (e.g. `agentstack-server-audience`) containing a protocol
     mapper with `protocolMapper: oidc-audience-mapper` and config
     `included.custom.audience: agentstack-server` — the **literal client id**,
     not `nextauthUrl`/`apiUrl`/any public base URL;
   - mapper config matching the bundled job: `id.token.claim: "false"`,
     `access.token.claim: "true"` (the audience must land in the **access** token,
     which is what the server validates);
   - that scope assigned as a **default** scope on the `agentstack-ui` client, so
     tokens minted for the UI carry `aud: agentstack-server`;
   - this pairs with `auth.validateAudience: true` + `serverClientId: agentstack-server`
     on the server side (§2). Get all three consistent or the API returns 401.
5. **Roles + role mapping.** `rolesPath: realm_access.roles` (the chart's
   `agentstack.oidc.rolesPath` helper, rendered as the server env var
   `AUTH__OIDC__ROLES_PATH`) means roles are read from the realm-access roles
   claim. The bundled 0.7.2 provisioner creates exactly **two realm roles**:
   `agentstack-admin` and `agentstack-developer`. Garrison must create the same
   realm roles in the `agentstack` realm so they appear in `realm_access.roles`.
   (The separate `user`/`developer`/`admin` tiers under `rateLimit.roleBasedLimits`
   are a different, optional axis — only consumed when `rateLimit.enabled: true`,
   which defaults to `false`. Don't confuse them with the realm roles.)
6. **Seed users.** Create an admin user with the `agentstack-admin` realm role
   assigned in the `agentstack` realm. (The bundled chart does this via a
   `seedAgentstackUsers` loop in the provision job; garrison reproduces it with
   the realm-import seed-user pattern from
   `keycloak/templates/realmimport.yaml.j2`, or via REST after import.)

## 4. In-cluster issuer + TLS engineering to reproduce

### 4.1 Dual issuer — RESOLVED

**This was §4.1's "top unknown". The pattern is now proven by armory's Headlamp
deployment and can be reused verbatim.**

Armory resolves the dual-issuer problem for Headlamp pods by injecting a
`hostAlias` into the Deployment that maps the public hostname (e.g. `armory.local`)
to the nginx ingress controller's in-cluster ClusterIP. This means pods use the
**public issuer URL** (`https://<armory-host>/realms/agentstack`) for all OIDC
operations — discovery, token validation, browser redirects — with no URL
divergence. The `hostname.strict: false` in the Keycloak CR prevents in-cluster
HTTP redirects to the public hostname.

Garrison must apply the same pattern to AgentStack UI and server pods:

```python
# Pseudocode — exact steps per armory's headlamp/tasks/deploy.yml lines 296–333
ingress_cluster_ip = kubectl get svc ingress-nginx-controller -n ingress-nginx \
                     -o jsonpath='{.spec.clusterIP}'

kubectl patch deployment <agentstack-ui> --type=strategic --patch '{
  "spec": {"template": {"spec": {
    "hostAliases": [{"ip": "<ingress_cluster_ip>",
                     "hostnames": ["<armory-host>"]}]
  }}}
}'
# Repeat for the agentstack server deployment
```

See [`headlamp/tasks/deploy.yml` lines 296–333](../ansible/roles/headlamp/tasks/deploy.yml)
for the exact idempotent Ansible implementation to copy.

### 4.2 Armory Keycloak is now HTTPS-only internally

**This is a significant change from what earlier notes described.**

The Keycloak CR in armory has `http.httpEnabled: false`. There is **no plain-HTTP
port 8080**. All in-cluster access — admin REST API calls, OIDC discovery, token
endpoints — goes through **HTTPS on port 8443** (`keycloak-service.keycloak.svc.cluster.local:8443`).

The internal TLS cert (`keycloak-internal-tls`) is issued by cert-manager from
the **`openbao-pki-internal` ClusterIssuer** (backed by OpenBao's `pki-int` mount).
Its SAN is `keycloak-service.keycloak.svc.cluster.local`.

**Implication for garrison**: Separate the bootstrap and runtime trust paths.
Any in-cluster call garrison makes to armory's Keycloak admin REST API (for
example to provision the `agentstack` realm) must:
- Target `https://keycloak-service.keycloak.svc.cluster.local:8443`
- Present armory's **internal CA** (`GET /v1/pki-int/ca/pem` from OpenBao, or
  read the `openbao-ca` secret from the `keycloak` namespace) for cert validation.

OIDC discovery, token validation, and browser redirects must instead use the
public issuer URL (`https://<armory-host>/realms/agentstack`) with hostAlias
resolution inside the AgentStack pods.

The `prepare_internal_https_caller.yml` common task encapsulates this CA
acquisition pattern. See [`headlamp/tasks/oidc_client.yml` lines 1–22](../ansible/roles/headlamp/tasks/oidc_client.yml)
for a complete working example.

### 4.3 TLS trust — two CA roots required

Garrison pods need to trust **two separate CA chains** from armory's OpenBao PKI:

| Use | CA | OpenBao endpoint | Secret |
|---|---|---|---|
| In-cluster Keycloak admin REST API calls | Internal Issuing CA (`pki-int`) | `GET /v1/pki-int/ca/pem` | `openbao-ca` in `openbao` ns |
| OIDC discovery/token validation over public URL (browser + pod) | External Issuing CA (`pki-ext`) | `GET /v1/pki-ext/ca/pem` | CA embedded in `armory-tls` secret |

In practice: for Ansible provisioning tasks calling the internal API, use the
internal CA bundle. For AgentStack pods doing OIDC validation against the public
issuer URL (via the hostAlias → nginx path), use the external CA mounted as
`NODE_EXTRA_CA_CERTS` (or equivalent). The external CA signs the nginx ingress
`armory-tls` certificate.

trust-manager `Bundle` CRDs can distribute either CA bundle to garrison namespaces
without manual copying — the preferred approach at scale.

### 4.4 Proxy/trust flags

Armory's Keycloak CR sets `proxy.headers: xforwarded` and armory's nginx ingress
passes `X-Forwarded-*` headers. Garrison's UI/API ingress must also set these
headers (nginx does this by default when configured correctly).

**IMPORTANT — these flags are now chart-native in 0.7.2; do NOT patch
Deployments.** Armory's old approach (`kubectl patch` to inject env vars onto
AgentStack pods) is obsolete. In 0.7.2 the chart renders the relevant env vars
directly from values:

| Container | Env var (rendered by chart) | Driven by value |
|---|---|---|
| server | `TRUST_PROXY_HEADERS` | top-level `trustProxyHeaders` |
| server | `AUTH__OIDC__INSECURE_TRANSPORT` | derived from the issuer scheme (HTTP vs HTTPS) |
| server | `AUTH__OIDC__VALIDATE_AUDIENCE` | `auth.validateAudience` |
| server | `AUTH__OIDC__CLIENT_ID` | `agentstack.oidc.serverClientId` |
| server | `AUTH__OIDC__ROLES_PATH` | `agentstack.oidc.rolesPath` |
| server | `AUTH__OIDC__ISSUER` / `AUTH__OIDC__EXTERNAL_ISSUER` | issuer helpers |
| ui | `TRUST_PROXY_HEADERS` | top-level `trustProxyHeaders` |
| ui | `NEXTAUTH_URL`, `NEXTAUTH_SECRET`, `OIDC_PROVIDER_*` | `auth.*` / `externalOidcProvider.*` |

So garrison sets **`trustProxyHeaders: true`** in Helm values (default is `false`)
rather than patching pods — that single value drives `TRUST_PROXY_HEADERS` on both
the UI and server containers, replacing the old `TRUST_PROXY_HEADERS` patch.

`AUTH__OIDC__INSECURE_TRANSPORT` is **not** a value garrison should force on:
because the public issuer URL is HTTPS (`https://<armory-host>/realms/agentstack`),
the chart resolves insecure-transport to `false` on its own. Only the legacy
plain-HTTP issuer needed it set to `true`; that no longer applies (armory Keycloak
is HTTPS-only, §4.2). Leave it at the chart default.

`AUTH_TRUST_HOST` (the Auth.js / NextAuth v5 variable from armory's old notes) is
**not rendered by the 0.7.2 chart at all** — the UI deployment sets `NEXTAUTH_URL`
+ `TRUST_PROXY_HEADERS` instead. Garrison does not need it under the standard
nginx-fronted ingress path. Only add it (via the chart's UI `extraEnv`, if the
installed version exposes one) if NextAuth host-validation errors actually appear
in UI logs; do not set it speculatively.

### 4.5 Required chart secrets with NO `existingSecret` hook

Two chart values are **required** but, unlike the OIDC client secrets (§3.3), have
**no `existingSecret` indirection** in 0.7.2. The OpenBao→VSO→k8s-Secret delivery
pattern therefore **does not apply** to them — they are plain Helm-value inputs and
must be supplied at render time.

| Value | 0.7.2 chart behaviour | Garrison delivery |
|---|---|---|
| `encryptionKey` | `encryptionKey: {{ .Values.encryptionKey \| b64enc \| quote }}` — **no fallback, no auto-gen, no validation**. Empty value → empty secret → broken at runtime. | Generate once, store in OpenBao KV, and **inject at deploy time as a Helm value** (Ansible reads it from OpenBao and passes `-e`/`--set`). It cannot be a VSO-synced Secret. |
| `auth.nextauthSecret` | If empty, the UI secret template auto-generates `randAlphaNum 32` and **persists it** via a `lookup` of `agentstack-ui-secret` (key `authSecret`). | Use the chart default and let it own/persist this value unless you explicitly choose to source it from OpenBao as a Helm value. There is no synced-Secret path here. |

> **Why this is called out:** the obvious instinct is "reuse the client-secret
> VSO pattern for these." That is wrong — there is no `existingSecret` for either.
> `encryptionKey` in particular fails silently (empty → empty secret), so it must
> be a deploy-time Helm value sourced from OpenBao, not a synced Secret.

### 4.6 AgentStack ingress (garrison-owned, integration-relevant)

The chart ships `templates/ingress.yaml` but the ingress block is **disabled by
default** in `values.yaml`. Garrison must define the UI ingress, and it is not
purely cosmetic — three integration points depend on it:

- the UI host is the `agentstack-ui` client's `redirectUris` / `webOrigins` (§3.2);
- it is where the `X-Forwarded-*` headers originate that §4.4 relies on (nginx
  ingress passes these by default with the right config — set
  `ingressClassName: nginx`);
- its TLS cert must be signed by armory's **external** issuing CA so that pods
  trusting `pki-ext` (§4.3) accept it. Issue it with cert-manager from the
  `openbao-pki-external` ClusterIssuer, SAN = the UI host.

**Knowable now:** the TLS/issuer pattern, the ingress class, and the default
`X-Forwarded-*` behaviour above. **A decision (not knowable):** the actual UI
hostname — garrison picks it, then it must be kept consistent across the ingress,
the `agentstack-ui` redirect URIs/web origins, and the cert SAN.

## 5. Network / topology

**Same-cluster AND same-VM confirmed (DECISION 2026-06-19).** Garrison deploys
into armory's existing single-node k3s cluster — which, because armory is one
Fedora Vagrant VM, means the **same VM**. Garrison gets **no Vagrantfile and no
VM of its own**. It is a separate git repo whose Ansible runs *inside armory's
VM*, against *armory's kubeconfig*, as a **follow-on after armory's `site.yml`**.
It therefore assumes armory's platform (k3s, OpenBao, Keycloak operator,
nginx-ingress, VSO, cert-manager, trust-manager) is already up; a light preflight
asserts those dependencies rather than provisioning them. The current armory
implementation uses cross-namespace service DNS
(`keycloak-service.keycloak.svc.cluster.local`) for all in-cluster Keycloak
access; garrison reuses that path directly. Namespace (`agentstack`) is the
isolation boundary between garrison and armory workloads.

- **Target namespace (DECISION — must be made, then enumerated)**: The doc never
  names garrison's AgentStack namespace, yet several mechanisms bind to it: the
  VSO `VaultStaticSecret` destination namespace for client secrets (§3.3, §6),
  the trust-manager `Bundle` target namespaces for CA distribution (§4.3), and
  the hostAlias patch (§4.1) all need the same namespace value. Pick one
  namespace up front and reuse it consistently across the Helm release
  namespace, the VSO resources, and the trust-manager Bundle targets. This is a
  decision, not a discoverable fact, but it must be fixed before building.
- **Realm ownership**: Garrison owns the `agentstack` realm end-to-end. Armory's
  `armory` realm (used by Headlamp and k3s OIDC) has no dependency on it.
- **Theme**: Armory runs a stock Keycloak image (not `keycloak-themed`). The Agent
  Stack login theme is not present. If the themed login is desired, garrison or
  armory must import it separately. Cosmetic delta, not a blocker.
- **Separate-cluster path**: **De-scoped (2026-06-19).** Garrison runs in
  armory's VM/cluster, so this path is not built. (For reference, were it ever
  revived: all Keycloak access would go via the public ingress
  `https://<armory-host>/realms/agentstack`, DNS would have to resolve, only the
  external CA would be needed, and the ingress would have to expose Keycloak
  admin endpoints — none of which applies same-cluster.)

## 6. Carried-over assets garrison should reuse

- **Realm/client provisioning pattern**: The GET→POST/PUT idempotent REST pattern
  in [`headlamp/tasks/oidc_client.yml`](../ansible/roles/headlamp/tasks/oidc_client.yml)
  is the proven template for provisioning clients in armory's Keycloak.
  Adapt it to target the `agentstack` realm instead of `armory`.
- **Admin token acquisition**: Use the `keycloak-bootstrap-admin` Secret (keys:
  `username`, `password`) in the `keycloak` namespace. POST to
  `https://keycloak-service.keycloak.svc.cluster.local:8443/realms/master/protocol/openid-connect/token`
  with `client_id: admin-cli`, `grant_type: password`. Pass the internal CA
  bundle (`ca_path`) for TLS validation.
- **Credential delivery (OpenBao + VSO)**: The `VaultConnection` → `VaultAuth` →
  `VaultStaticSecret` pattern in [`keycloak/templates/`](../ansible/roles/keycloak/templates/)
  is the reference for storing client secrets in OpenBao KV and syncing them
  into k8s Secrets. Use the same pattern for `agentstack-ui` and `agentstack-server`
  client secrets, then reference the resulting Secret via
  `externalOidcProvider.existingSecret`. **Caveat:** this pattern applies *only*
  to the OIDC client secrets. `encryptionKey` and `auth.nextauthSecret` have no
  `existingSecret` hook and must be delivered as Helm values, not synced Secrets
  (§4.5).
- **Realm import (declarative)**: The `KeycloakRealmImport` CRD pattern in
  [`keycloak/templates/realmimport.yaml.j2`](../ansible/roles/keycloak/templates/realmimport.yaml.j2)
  is the preferred way to bootstrap a realm. Note the comment in that template:
  do **not** declare `clientScopes` in the import — it suppresses Keycloak's
  built-in scopes and breaks OIDC sign-in. Bootstrap the realm via import; add
  clients and scopes via REST after the realm exists.
- **hostAlias pattern**: [`headlamp/tasks/deploy.yml` lines 296–333](../ansible/roles/headlamp/tasks/deploy.yml)
  implements the ingress-IP hostAlias injection. Replicate for AgentStack pods.
- **Internal HTTPS caller setup**: [`common/tasks/prepare_internal_https_caller.yml`](../ansible/roles/common/tasks/prepare_internal_https_caller.yml)
  fetches the OpenBao internal CA and writes a trusted bundle to a temp path,
  ready for `ca_path:` in `ansible.builtin.uri` calls. Use this for all
  in-cluster Keycloak admin API calls.

## 7. Open items checklist

- [x] ~~Confirm `externalOidcProvider.issuerUrl` single-issuer handling vs the
      internal/external split (§4.1)~~ — **RESOLVED**: use public issuer URL
      everywhere + hostAlias injection for DNS resolution inside pods.
- [x] ~~Decide same-cluster vs separate-cluster topology (§5)~~ — **RESOLVED**:
      same-cluster confirmed.
- [ ] Define the `agentstack` realm: clients, secrets, audience scope+mapper,
      roles, seed admin (§3). **SPEC NAILED DOWN** (still garrison's build task):
      - clients: `agentstack-ui` (confidential, `standardFlowEnabled: true`,
        `publicClient: false`) and `agentstack-server` (confidential,
        `standardFlowEnabled: false`, `serviceAccountsEnabled: true`). The bundled
        chart also sets `directAccessGrantsEnabled: true` (ROPC) on the server
        client — **start with it `false`** and only re-enable if CLI/automation
        login breaks (security note in §3.2; not knowable statically). Tighten the
        bundled chart's wildcard `redirectUris: ["*", ...]` / `webOrigins: ["*"]`
        to the real UI host.
      - audience: client scope `agentstack-server-audience` with an
        `oidc-audience-mapper` whose `included.custom.audience` is the **literal**
        `agentstack-server` (NOT a URL — §3.4 bug), `access.token.claim: "true"`,
        assigned as a **default** scope on `agentstack-ui`.
      - roles: realm roles `agentstack-admin` and `agentstack-developer` (§3.5).
      - seed admin: one user with `agentstack-admin` (§3.6).
- [x] ~~Establish CA-trust delivery from armory to garrison pods (§4.3)~~  —
      **RESOLVED**: internal CA (`pki-int`) for admin API calls; external CA
      (`pki-ext`) for OIDC validation over public URL. trust-manager `Bundle`
      CRDs are the preferred distribution mechanism.
- [x] ~~Confirm `existingSecret` shape: keys `uiClientSecret` / `serverClientSecret`.~~
      — **RESOLVED** against 0.7.2: the chart defaults
      `uiClientSecretKey: "uiClientSecret"` and
      `serverClientSecretKey: "serverClientSecret"`, so those are the two required
      keys (§2). Override the `*SecretKey` values only if VSO emits different keys.
- [x] ~~Validate `rolesPath: realm_access.roles` against the roles garrison defines.~~
      — **RESOLVED**: the server consumes it as `AUTH__OIDC__ROLES_PATH`; the
      bundled 0.7.2 provisioner defines realm roles `agentstack-admin` and
      `agentstack-developer`. Define those exact realm roles so they surface in
      `realm_access.roles` (§3.5).
- [x] ~~Decide whether to import the Agent Stack Keycloak login theme.~~ —
      **RESOLVED (decision): accept the default Keycloak theme.** Armory runs the
      stock Keycloak image; the themed login is a cosmetic delta, not a blocker
      (§5). Revisit only if branding is later required, at which point armory must
      switch to a themed image (a shared-IdP change, so coordinate with armory).
- [x] ~~Confirm which proxy/trust env vars are still required.~~ — **RESOLVED**
      against 0.7.2 (§4.4): set `trustProxyHeaders: true` in Helm values (drives
      `TRUST_PROXY_HEADERS` on UI + server). Do **not** patch Deployments — these
      are chart-native now. `AUTH__OIDC__INSECURE_TRANSPORT` stays at the chart
      default (`false`, since the issuer is HTTPS). `AUTH_TRUST_HOST` is not
      rendered by the chart and is not needed under the nginx ingress path.
- [ ] Deliver `encryptionKey` and `auth.nextauthSecret` (§4.5). Neither has an
      `existingSecret` hook, so the VSO pattern does **not** apply. `encryptionKey`
      is mandatory and fails silently when empty — generate it, store in OpenBao,
      and inject as a Helm value at deploy time. `nextauthSecret` can be left for
      the chart to auto-generate/persist, or supplied as a value.
- [ ] Define the AgentStack UI ingress (§4.6): pick the UI hostname, issue its TLS
      cert from the `openbao-pki-external` ClusterIssuer (SAN = UI host),
      set `ingressClassName: nginx`, and keep the host consistent with the
      `agentstack-ui` redirect URIs / web origins and the cert SAN.
- [ ] Decide garrison's AgentStack **namespace** (§5) and apply it consistently
      across the Helm release, the VSO `VaultStaticSecret` destination, and the
      trust-manager `Bundle` targets. A decision, but it gates those mechanisms.
- [ ] **Needs runtime confirmation (not knowable statically):** whether
      `directAccessGrantsEnabled` (ROPC) is actually required on `agentstack-server`
      (§3.2). Default to `false`; re-enable only if CLI/automation login fails.
