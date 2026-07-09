# project-garrison

Deploy-only Ansible repo that stands up the **BeeAI / Agent Stack** Helm chart
(`agentstack`, OCI chart `oci://ghcr.io/i-am-bee/agentstack/chart/agentstack`)
against the **external Keycloak** owned by the sibling project **armory**.

Garrison runs *inside armory's k3s VM*, as a follow-on after armory's `site.yml`.
It assumes armory's platform is already up (k3s, OpenBao, Keycloak, nginx-ingress,
VSO, cert-manager, trust-manager) and only provisions the Agent Stack:
its Keycloak realm/clients, all secrets, a self-rolled Postgres, and the Helm release.

- **Namespace:** `agentstack`
- **UI URL:** `https://agentstack.armory.local`
- **Realm:** `agentstack` (in armory's Keycloak at `https://armory.local/realms/agentstack`)

---

## Prerequisites

- Armory's `site.yml` has completed; its platform is running in the VM.
- `.env` at the repo root is configured (see `.env.example`). Key variables:

  | Variable | Typical value | Purpose |
  |---|---|---|
  | `ARMORY_PROJECT_ROOT` | `/opt/project-armory` | Where armory lives |
  | `GARRISON_PROJECT_ROOT` | `/opt/project-garrison` | Where garrison lives |
  | `ARMORY_KUBECONFIG_PATH` | `/etc/rancher/k3s/k3s.yaml` | kubeconfig for all k8s/helm tasks |
  | `GARRISON_ANSIBLE_ROOT` | `${GARRISON_PROJECT_ROOT}/ansible` | Auto-derived |
  | `ANSIBLE_ROLES_PATH` | `roles` | Role resolution (see gotcha below) |

> All commands below assume you are **on the VM** (`vagrant ssh`) and that
> `kubectl` means `sudo k3s kubectl` (k3s bundles it). Add an alias if you like:
> `alias kubectl='sudo k3s kubectl'`.

---

## Lifecycle

### Bring up

`bringup-all.sh` (repo root) is the orchestrator. It sources `.env` correctly and
runs the playbook(s) for you.

```bash
cd /opt/project-garrison

# Inner loop — garrison only (fast; armory platform already running).
# This is the normal day-to-day command.
./bringup-all.sh --garrison-only

# Outer loop — rebuild armory first, then garrison (slow; full reset).
# Use after `vagrant destroy/up`, or when k3s/Keycloak/OpenBao state is unknown.
# NOTE: the armory rebuild WIPES garrison's realm + OpenBao KV paths.
./bringup-all.sh

# Preview without executing
./bringup-all.sh --dry-run

# Help
./bringup-all.sh --help
```

### Tear down (garrison only — leaves armory intact)

There is no teardown flag on `bringup-all.sh`; run the playbook directly. It
**requires an explicit confirmation flag** as a safety gate.

```bash
cd /opt/project-garrison/ansible
set -a; source ../.env; set +a          # see gotcha below — the `set -a` matters
ansible-playbook playbooks/teardown.yml -e teardown_confirm=true
```

Teardown destroys: the Helm release, the `agentstack` namespace, the `agentstack`
Keycloak realm, garrison's OpenBao KV paths, and garrison's CA trust anchor. It
does **not** touch armory.

### Run `site.yml` directly (advanced)

`bringup-all.sh --garrison-only` is just a wrapper around this:

```bash
cd /opt/project-garrison/ansible
set -a; source ../.env; set +a
ansible-playbook playbooks/site.yml

# Re-run a single phase via tags, e.g. just the Keycloak realm/clients:
ansible-playbook playbooks/site.yml --tags agentstack_keycloak
# Other tags: openbao, agentstack_secrets, agentstack_db, agentstack, agentstack_deploy
```

### ⚠️ The `set -a` gotcha

Sourcing `.env` **without** `set -a` sets the variables only in your shell — they
are **not exported** to the `ansible-playbook` child process, so `ANSIBLE_ROLES_PATH`
never reaches Ansible and you get:

```
ERROR! the role 'common' was not found ...
```

Always wrap it: `set -a; source ../.env; set +a`. (`bringup-all.sh` does this for
you — this only bites when you run the playbooks by hand.)

---

## Logging in / retrieving credentials

After a successful bringup, the Agent Stack admin user is created in the
`agentstack` realm and its credentials are surfaced as a k8s Secret.

```bash
# Username
sudo k3s kubectl get secret agentstack-admin-credentials -n agentstack -o jsonpath='{.data.username}' | base64 -d; echo

# Password
sudo k3s kubectl get secret agentstack-admin-credentials -n agentstack \
  -o jsonpath='{.data.password}' | base64 -d; echo
```

Log in at **`https://agentstack.armory.local`** (redirects to Keycloak). Your
*browser host* must resolve `agentstack.armory.local` and `armory.local` to the
VM's ingress — add them to your host's `/etc/hosts` (or `C:\Windows\System32\drivers\etc\hosts`)
pointing at the VM IP if they don't already.

> After re-provisioning, **sign out / use a private window** so Keycloak mints a
> fresh token — a cached session from a previous deploy can carry a stale token.

### OpenBao break-glass (fallback)

OpenBao is the source of truth for every secret. To read a value directly (e.g.
if VSO sync is lagging), decrypt the break-glass root token and query the KV:

```bash
TOKEN=$(sudo ansible-vault decrypt --vault-password-file /opt/openbao/.vault-pass \
          --output - /opt/openbao/init-keys.yml \
        | python3 -c "import sys,yaml; print(yaml.safe_load(sys.stdin)['root_token'])")

# Example: the seed-admin password (KV v2 under secret/garrison/…)
curl -sk -H "X-Vault-Token: $TOKEN" \
  https://openbao.openbao.svc.cluster.local:8200/v1/secret/data/garrison/seed-admin-password \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['data']['data']['password'])"
```

Garrison's KV paths live under `secret/garrison/` — e.g. `agentstack-postgres`,
`agentstack-oidc-client-secrets`, `agentstack-encryption-key`,
`agentstack-nextauth-secret`, `seed-admin-password`.

---

## CLI (agentstack server login)

The `agentstack-cli` pip package is the CLI counterpart to the Helm-deployed server.
Install it in a dedicated venv on the VM:

```bash
python3 -m venv /opt/agentstack-cli/.venv
source /opt/agentstack-cli/.venv/bin/activate
pip install agentstack-cli
```

### ⚠️ The CLI targets the SERVER, not the UI host

The browser logs in at the UI host (`https://agentstack.armory.local`). **The CLI does
not** — that host is a browser-only BFF: its `/api/*` proxy honours the NextAuth *session
cookie* and ignores Bearer tokens, and it does not serve the OAuth discovery endpoint
the CLI needs (`/.well-known/oauth-protected-resource`). Pointing the CLI at it fails
with `JSONDecodeError` / `Unauthorized`.

The CLI uses the **MCP-style OAuth flow** (RFC 9728 discovery → OIDC metadata → Auth
Code + PKCE in a browser → `http://localhost:9001/callback`) and talks **directly to
`agentstack-server-svc`**. That requires the server to be exposed on its own ingress
host (see ticket 001 Phase 4 — `agentstack-api.armory.local`) and a dedicated public
`agentstack-cli` Keycloak client. (No ROPC / password grant is involved.)

### Prerequisites (internal TLS + local DNS)

Python does not use the OS trust store, and the VM's own `/etc/hosts` may lack the api
host:

```bash
# DNS: map the api ingress host to the k3s node loopback (klipper-lb binds here)
grep -q "api.agentstack.armory.local" /etc/hosts || echo "127.0.0.1 api.agentstack.armory.local" | sudo tee -a /etc/hosts

# SSL: expose the garrison-installed CA (under /etc/pki/ca-trust/…) to Python
export SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
export REQUESTS_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
```

> The CA env vars must be set in every shell session before running `agentstack`
> commands. Add them to `/etc/profile.d/agentstack-cli.sh` to make them permanent.

### Login

The CLI opens a browser and listens on `127.0.0.1:9001` for the OAuth callback. On the
headless VM, either tunnel that port to a machine with a browser
(`vagrant ssh -- -L 9001:localhost:9001`, then open the printed URL on your host), or
run the CLI from your desktop (it already trusts the CA + resolves the hosts).

```bash
source /opt/agentstack-cli/.venv/bin/activate
export SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
export REQUESTS_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem

# Confirm discovery works (must return JSON, not HTML)
curl -s https://api.agentstack.armory.local/.well-known/oauth-protected-resource/ | python3 -m json.tool

agentstack server login https://api.agentstack.armory.local --client-id agentstack-cli
```

### Deploying reference agents

After login, deploy any agent with a `Dockerfile` at the repo root:

```bash
agentstack add https://github.com/jenna-winkler/agentstack-showcase
# or with a pinned ref:
agentstack add https://github.com/i-am-bee/agentstack@v0.7.1#path=/agents/<agent-name>

agentstack list          # confirm registered
agentstack run <agent>   # test via CLI
```



See [agentstack reference agents](https://github.com/i-am-bee/agentstack#reference-agents)
for the list of targets.

---

## Architecture (what gets provisioned)

`site.yml` runs these roles in order:

| Phase | Role | Provisions |
|---|---|---|
| 0 | `preflight` | Asserts armory's platform is up |
| 0 | `openbao_bootstrap` | Garrison KV prefix + scoped provisioner token + k8s-auth role |
| 1 | `agentstack_keycloak` | `agentstack` realm, `agentstack-ui`/`agentstack-server` clients, audience scope, realm roles, seed admin |
| 2 | `agentstack_secrets` | All secrets in OpenBao → k8s via VSO; trust-manager CA bundles; Postgres TLS cert |
| 3a | `agentstack_db` | Self-rolled `pgvector/pgvector:pg16` StatefulSet (replaces the Bitnami subchart) |
| 3b | `agentstack` | Helm release + UI ingress cert + dual-issuer pod patch + readiness gate |

Key design points:
- **OpenBao is the single source of truth** for all secrets; workload secrets are
  delivered to pods as k8s Secrets via VSO `VaultStaticSecret`. The two hookless
  chart secrets (`encryptionKey`, `auth.nextauthSecret`) and the DB SSL CA are
  injected as Helm values at deploy time.
- **Dual-issuer trust:** the UI + server pods get a `hostAlias`
  (`armory.local` → ingress ClusterIP) plus the private CA mounted in-pod, with
  `NODE_EXTRA_CA_CERTS` (Node UI) and `SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE`
  (Python server) so they can reach/validate the public HTTPS issuer.

---

## Troubleshooting

General triage:

```bash
sudo k3s kubectl get po -n agentstack                 # everything should be Running / 1-1
sudo k3s kubectl logs -n agentstack deploy/agentstack-server -c agentstack --tail=50
sudo k3s kubectl logs -n agentstack deploy/agentstack-ui --tail=50
sudo k3s kubectl describe po -n agentstack <pod>      # for Init/CreateContainerConfigError detail
sudo k3s kubectl logs -n ingress-nginx deploy/ingress-nginx-controller --tail=50 | grep agentstack
```

Issues seen during bring-up and their fixes (all now handled in the roles — listed
here for diagnosis if they recur):

| Symptom | Cause | Resolution |
|---|---|---|
| `role 'common' was not found` | `.env` sourced without `set -a` | `set -a; source ../.env; set +a` |
| `Invalid kube-config file. No configuration found` | task read `K8S_AUTH_KUBECONFIG` via `lookup(env)` (controller env, unset) | rely on the play-level `environment:`; don't pass `kubeconfig: lookup(...)` |
| Wait for VSO secret times out, key missing | VSO `refreshAfter` (1h) serves a stale KV version | the role force-syncs VSO after each write; to force manually: `kubectl annotate vaultstaticsecret <name> -n agentstack vso.hashicorp.com/force-sync=$(date +%s) --overwrite` |
| Server pod `Init:CreateContainerConfigError`, "couldn't find key sqlConnectionSuperuser" | secret missing the superuser DB URL | Phase 2 writes `sqlConnectionSuperuser` into the Postgres secret |
| `create-pgvector-extension` crashloops on `CREATE EXTENSION vector` | image lacks pgvector | DB uses `pgvector/pgvector:pg16`, not `postgres:16` |
| Server crashloops: `load_verify_locations ... cannot be all omitted` | `DB_USE_SSL=true` requires a CA | Phase 3 injects `externalDatabase.sslRootCert` from the `agentstack-postgresql-tls` `ca.crt` |
| **502 Bad Gateway after login** | nginx proxy buffer too small for the large NextAuth session cookie (`upstream sent too big header`) | ingress annotations `proxy-buffer-size: 64k`, `proxy-buffers-number: 8` |
| **401 / "Server authentication failed" after login**, server log `CERTIFICATE_VERIFY_FAILED` | Python server can't verify the issuer TLS (only `NODE_EXTRA_CA_CERTS` set, which is Node-only) | server gets `SSL_CERT_FILE` + `REQUESTS_CA_BUNDLE` → the mounted CA bundle |
| **401**, server log `missing_claim: Missing 'sub' claim` | `agentstack-ui` client missing the built-in `basic` scope (holds the `sub` mapper in Keycloak 24+) | `agentstack_ui_default_client_scopes` includes `basic` + `acr` |
| **401**, server log `invalid_claim: Invalid claim 'aud'` | Server (0.7.1) builds `expected_aud` from `create_resource_uri(request.url)` — a URL — but token carries `aud=['agentstack-server','account']` | `auth.validateAudience: false` in Helm values; iss/sub/exp/sig still validated |

Inspecting Keycloak (read-only) for client/scope issues:

```bash
KC=https://keycloak-service.keycloak.svc.cluster.local:8443
U=$(sudo k3s kubectl get secret keycloak-bootstrap-admin -n keycloak -o jsonpath='{.data.username}' | base64 -d)
P=$(sudo k3s kubectl get secret keycloak-bootstrap-admin -n keycloak -o jsonpath='{.data.password}' | base64 -d)
TOK=$(curl -sk -d client_id=admin-cli -d "username=$U" -d "password=$P" -d grant_type=password \
        $KC/realms/master/protocol/openid-connect/token | python3 -c 'import sys,json;print(json.load(sys.stdin)["access_token"])')
CID=$(curl -sk -H "Authorization: Bearer $TOK" "$KC/admin/realms/agentstack/clients?clientId=agentstack-ui" \
        | python3 -c 'import sys,json;print(json.load(sys.stdin)[0]["id"])')
# default scopes on the UI client (must include basic, acr, and agentstack-server-audience)
curl -sk -H "Authorization: Bearer $TOK" "$KC/admin/realms/agentstack/clients/$CID/default-client-scopes" \
  | python3 -c 'import sys,json;[print(s["name"]) for s in json.load(sys.stdin)]'
```
