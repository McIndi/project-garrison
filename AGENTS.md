# AGENTS.md — project-garrison

Guidance for any agent (Copilot, Claude, etc.) working in this repo. Self-contained:
do **not** assume parent-directory/workspace conventions — everything garrison needs
is here or in the two docs named below.

## What this is

Garrison deploys the BeeAI / **Agent Stack** Helm chart (`agentstack`, pinned
`0.7.2`) with its **bundled Keycloak disabled**, pointed at the **external**
Keycloak owned by the sibling project **armory**. It is **deploy-only Ansible** —
it provisions the `agentstack` realm/clients, secrets, an external Postgres, and
the Helm release. It does **not** stand up the platform; armory already runs k3s,
OpenBao, the Keycloak operator, nginx-ingress, VSO, cert-manager, and trust-manager.

- **Spec (what must be true):** [`agentstack-keycloak-reqs-for-garrison.md`](agentstack-keycloak-reqs-for-garrison.md)
- **Build plan (how/when, running log):** [`tickets/open/001-agentstack-external-keycloak.md`](tickets/open/001-agentstack-external-keycloak.md)

## Run model

- **No VM of its own.** Garrison runs **inside armory's single-node Fedora VM**
  (repo mounted under `/vagrant`), against **armory's kubeconfig**, as a
  **follow-on after armory's `site.yml`**. There is no `Vagrantfile` here.
- A light **`preflight` role** asserts armory's platform is up (Keycloak/OpenBao/
  ingress/VSO/trust-manager reachable + Ready) and fails fast otherwise. It does
  not provision anything.
- **Validation runs in the VM**, not on a Windows host (`ansible-playbook` /
  `ansible-lint` aren't installed on the host).
- **Self-contained — never reach into armory's repo by filesystem path.** Do NOT
  `import_tasks`/`include_tasks`/`template` files under `../project-armory/...`;
  armory's on-disk location is not guaranteed (it is not nested under garrison).
  When you need an armory pattern (e.g. internal-CA acquisition, OpenBao token,
  the postgres StatefulSet), **vendor a copy into this repo** under
  `ansible/roles/...` and parameterize it. Reuse armory's *patterns*, not its
  *files in place*, and **never reuse armory's actual artifacts** (its root token,
  provisioner token, policies, secrets) — garrison creates its own
  garrison-named/scoped equivalents.
  - **Sole documented exception (break-glass bootstrap):** the one-time OpenBao
    bootstrap reads armory's **root token** from the VM's Vault-encrypted
    `/opt/openbao/init-keys.yml` (decrypted with `/opt/openbao/.vault-pass`),
    `no_log`, as root. It is used **once** to mint garrison's own scoped
    provisioner identity + policies + k8s-auth roles, then never persisted. This is
    the only place garrison touches an armory artifact; everything it *creates* is
    garrison-owned. Paths come from vars (defaulting to the two above).
- **All filesystem paths derive from `.env` vars** — never hardcode repo
  locations. Roots (`GARRISON_PROJECT_ROOT`, `GARRISON_ANSIBLE_ROOT`, and armory's
  if ever needed) come from `.env`; everything else is built from them
  (`${GARRISON_PROJECT_ROOT}/...`). The VM layout is NOT `/vagrant/...` by
  assumption — set the real roots in `.env` and derive from there.

## Engineering principles (non-negotiable)

**1. Supported modules over shelling out.** Prefer declarative modules; they are
idempotent by construction.

| Need | Use | Not |
|---|---|---|
| Install/upgrade chart | `kubernetes.core.helm` (+ `helm_repository`) | `command: helm` |
| Apply CRs/manifests | `kubernetes.core.k8s` (templated `definition`) | `kubectl apply -f -` |
| Read Secret / ClusterIP | `kubernetes.core.k8s_info` | `kubectl get -o jsonpath` |
| Patch a Deployment | `kubernetes.core.k8s` (`state: patched`) | `kubectl patch` |
| Realm/clients/scopes/roles/users | `community.general.keycloak_*` | hand-rolled `uri` REST |

**2. Idempotency is a design constraint.** Reads are `changed_when: false`; any
unavoidable `command` sets explicit `creates`/`changed_when`/`failed_when`. **No
fresh randomness per run** — secrets are generate-if-absent → persist in OpenBao →
read back, never re-randomized (that silently rotates creds and breaks
convergence). Never `--set` a freshly generated value into a Helm release.

**3. Internal-CA caveat.** armory's Keycloak is HTTPS-only on `:8443` with an
**internal (pki-int) CA**. `community.general.keycloak_*` must present that CA with
`validate_certs: true` (via `ca_path`, or `REQUESTS_CA_BUNDLE`/`SSL_CERT_FILE` in
the task `environment:`). If a specific module can't, **that step only** falls back
to a `uri` + `ca_path` REST call — don't abandon the module approach wholesale.

**4. OpenBao is the single source of truth for ALL secrets.** No chart default and
no chart auto-gen ships. Delivery splits by whether the chart exposes an
`existingSecret` hook: **hooked** → OpenBao KV → VSO `VaultStaticSecret` →
referenced Secret; **hookless** (`encryptionKey`, `auth.nextauthSecret`) → OpenBao
→ read by Ansible → injected as a Helm value at deploy time. This also forces
discovery/replacement of insecure chart defaults.

## Key decisions (see ticket for full rationale)

- **Namespace:** `agentstack` (the only isolation boundary from armory — same
  cluster). **UI host:** `agentstack.<armory-domain>`.
- **Realm:** garrison owns the `agentstack` realm end-to-end, including enabling
  **audit events** on it (login + admin, `jboss-logging`); armory owns only the
  listener/retention pipe.
- **ROPC** (`directAccessGrantsEnabled`) on `agentstack-server` starts **`false`**;
  only enable if the beeai CLI login actually breaks (runtime check).
- **Audience mapper** uses the **literal** `agentstack-server` client id, never a
  URL (works around the bundled chart's bug).
- **Postgres:** **no Bitnami subchart** — set `postgresql.enabled: false` and
  self-roll a `postgres:16` StatefulSet (copied from armory's keycloak role:
  official image, OpenBao/VSO creds, `pki-int` TLS), wired via the chart's
  `externalDatabase` block. Other subcharts (redis→cloudpirates, seaweedfs,
  phoenix) are not Bitnami and are used as-is.

## Dev workflow — two loops

Garrison and armory share one VM/cluster. Dependency is one-way (garrison → armory).

- **Inner loop (changed garrison):** redeploy in place. Clean reset =
  `teardown.yml` → `site.yml`. Does **not** touch armory.
- **Outer loop (changed armory):** `vagrant destroy/up` + armory `site.yml`,
  **then re-run garrison** (an armory rebuild wipes garrison's realm + OpenBao KV
  state).
- Rule of thumb: *edited armory? outer. edited only garrison? inner.* (~90% inner.)

## Commands (run inside armory's VM)

```bash
set -a; source .env; set +a            # load env (kubeconfig path, etc.)
cd "$GARRISON_ANSIBLE_ROOT"            # the ansible/ dir
ansible-galaxy collection install -r requirements.yml
ansible-playbook --syntax-check playbooks/site.yml
ansible-lint
ansible-playbook playbooks/site.yml    # deploy
# teardown (inner-loop reset), once it exists:
# ansible-playbook playbooks/teardown.yml -e teardown_confirm=true
```

> Collection deps in `requirements.yml` are **intentionally unpinned** during
> development to test latest — **pin before any demo.**
