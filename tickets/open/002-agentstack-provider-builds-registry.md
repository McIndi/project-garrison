# 002 — Provider builds: wire agentstack to armory's platform registry

**Status:** open · **Created:** 2026-06-24 (revised: registry moved to armory) ·
**Depends on:** armory's platform registry + node trust landing first
(`project-armory/doc/agentstack-registry-node-trust-plan.md`).

## Goal

Enable `agentstack add <github-url>` (the chart's "provider build" feature). The server
gates it: [`provider_build.py:60`](https://github.com/i-am-bee/agentstack/blob/main/apps/agentstack-server/src/agentstack_server/service_layer/services/provider_build.py)
raises `RuntimeError("OCI build registry is not configured")` when
`oci_build_registry_prefix` is empty — i.e. when `providerBuilds` is disabled (chart
default). We turn the feature on and point it at **armory's platform registry** (zot in
the `registry` namespace). "Done" = `agentstack add <repo>` builds, pushes to the registry,
and the agent pod pulls + runs.

## Scope (what's garrison's vs armory's)

- **Armory owns** the registry itself (zot deploy, TLS, htpasswd auth, PVC) **and** the
  node/containerd trust. See its plan. The push credential lives in OpenBao at
  `secret/platform/registry` (armory grants garrison read).
- **Garrison owns only the agentstack wiring:** the chart values + the
  `agentstack-registry-secret` (`dockerconfigjson`) in the `agentstack` namespace.

We do **NOT** deploy the chart's bundled `localDockerRegistry` (insecure HTTP, no auth —
the thing we're replacing).

## Contract (must match armory's plan)

| Item | Value |
|---|---|
| Registry in-cluster host (registryPrefix) | `registry-svc.registry:5001` |
| Build secret (fixed name the chart's Job requires) | `agentstack-registry-secret` (type `kubernetes.io/dockerconfigjson`), in ns `agentstack` |
| Push credential source | OpenBao `secret/platform/registry` → `username`, `password` (armory-owned; read granted to garrison) |
| Auth model | anonymous pull (containerd needs no cred), authenticated push (used by the build Job) |

Why the fixed secret name: the chart's build Job
(`…/default_templates/build-provider-job.yaml`) hardcodes
`imagePullSecrets: [agentstack-registry-secret]` and mounts it as the crane
`docker-config`. The chart only auto-creates it when `localDockerRegistry.enabled`; since
that's off, **garrison must create it**.

## Steps

### 1. Read the push credential (OpenBao read grant)

Confirm garrison's OpenBao policy/VSO can read `secret/platform/registry` (armory's plan
§1.7 grants it). If using a VSO `VaultStaticSecret`, it reads that path directly; if
reading via Ansible, the scoped provisioner token needs the read grant.

### 2. Create `agentstack-registry-secret` (dockerconfigjson)

In `agentstack_secrets` (new task `registry_secret.yml`, model on the existing OIDC/PG
secret tasks). Build a `kubernetes.io/dockerconfigjson` for host
`registry-svc.registry:5001` from the OpenBao creds:
```json
{ "auths": { "registry-svc.registry:5001":
  { "username": "<u>", "password": "<p>", "auth": "<base64(u:p)>" } } }
```
Preferred: a `VaultStaticSecret` with a **transformation template** rendering
`.dockerconfigjson` from the OpenBao creds (no plaintext through Ansible). Fallback: build
the JSON in Ansible (`no_log: true`) and apply with `kubernetes.core.k8s`. The Secret
**name must be exactly `agentstack-registry-secret`** in the `agentstack` namespace.

### 3. Chart values (`roles/agentstack/defaults/main.yml`, in `agentstack_helm_values`)

```yaml
localDockerRegistry:
  enabled: false                 # replaced by armory's platform registry
providerBuilds:
  enabled: true
  buildBackend: kaniko
  buildRegistry:
    registryPrefix: "registry-svc.registry:5001"      # armory's registry; NB the dot in ".registry"
    secretName: agentstack-registry-secret
    insecure: true               # matches the build Job's hardcoded `crane --insecure`; TLS still encrypts the wire
```
Then `helm template` with garrison's full value set and confirm the rendered server env
sets `oci_build_registry_prefix` (the gate from `provider_build.py:60`). Also confirm the
server SA has RBAC to create the build Job/Secret/Pod in `agentstack` when
`providerBuilds.enabled` — **add a Role/RoleBinding if the chart doesn't** (see Open items).

### 4. preflight assertion (armory dependency)

Add a `preflight` task that fails fast if armory's side isn't in place:
- the in-cluster registry is reachable: `kubernetes.core.k8s_info` finds Service
  `registry-svc` in ns `registry` with endpoints; and
- the node trust exists (garrison runs on the VM): `ansible.builtin.stat`
  `/etc/rancher/k3s/registry-ca.pem` and `slurp` `/etc/rancher/k3s/registries.yaml`
  asserting it contains `registry-svc.registry:5001`.
- `fail_msg`: "Deploy armory's platform registry + node trust first — see
  project-armory/doc/agentstack-registry-node-trust-plan.md".

### 5. Wire into `playbooks/site.yml`

No new role needed — the work lands in `agentstack_secrets` (the secret) and `agentstack`
(the values) + `preflight` (the assertion). Re-run order unchanged.

### 6. Teardown

`agentstack-registry-secret` lives in the `agentstack` ns → removed by the existing
namespace delete. No OpenBao KV to purge here (the credential is armory's at
`secret/platform/registry`).

## Verification (Done)

```bash
# 1) the 500 gate is gone — server has a build registry configured
sudo k3s kubectl get secret agentstack-registry-secret -n agentstack -o jsonpath='{.type}'  # kubernetes.io/dockerconfigjson

# 2) end-to-end
agentstack add https://github.com/jenna-winkler/agentstack-showcase
sudo k3s kubectl get jobs,pods -n agentstack -l managedBy=agentstack    # kaniko/crane Job → Completed
sudo k3s kubectl get pods -n agentstack | grep -i <agent>               # agent pod Running (pulled from armory's registry)
```

Failure triage: `OCI build registry is not configured` (500) → step 3 not applied / env
not set. Push errors → `agentstack-registry-secret` creds vs armory's htpasswd. Pull
errors (`ImagePullBackOff`, x509, no route) → armory node trust (CA SAN `127.0.0.1`,
mirror endpoint, ca_file).

## Open items to confirm during implementation

1. **Build RBAC** — does enabling `providerBuilds` grant the server SA rights to create
   the build Job/Secret/Pod in `agentstack`? If not, add a Role/RoleBinding. (Verify
   against the chart templates; this only surfaces at first `agentstack add`.)
2. **kaniko base-image pulls** — kaniko fetches the Dockerfile's base image over public
   TLS from inside the Job; confirm the build pod trusts public CAs (ties to bug #14's
   combined CA bundle if the build pod inherits our CA env).
3. **registryPrefix dot rule** — the chart requires a dot in the registry host;
   `registry-svc.registry` satisfies it. If the build complains, fall back to the FQDN
   `registry-svc.registry.svc.cluster.local:5001` (armory's cert already SANs it).
