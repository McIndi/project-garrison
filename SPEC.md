# Project Garrison — Build Specification
**McIndi Solutions LLC**
Version 0.3 — MVP / Local Development Target

---

## What This Is

Project Garrison is a sovereign agentic runtime for regulated enterprises. It provisions, governs, and audits AI agents as first-class infrastructure. Every agent spawned by Garrison has a cryptographic identity, scoped credentials with a defined TTL, a policy that describes exactly what it can touch, and a complete audit trail. When an agent's work is done, its credentials expire and its token is revoked.

This is not a chatbot framework. It is the infrastructure layer that makes agentic workloads auditable, governable, and safe to operate in regulated environments.

---

## Target Stack

| Concern | Tool | Notes |
|---|---|---|
| Container runtime (MVP) | Podman + podman-compose | Red Hat native, maps directly to OCP |
| Container runtime (prod) | OpenShift / ROKS (IBM Cloud) | IBM business partner target |
| Infrastructure as Code | OpenTofu (OSS Terraform fork) | MIT license, fully compatible |
| Secret management | OpenBao | PKI, dynamic creds, transit, audit |
| Agent runtime | BeeAI Framework | Apache-2.0, TypeScript-first, multi-agent + tool/plugin model |
| Human interface | Open WebUI | OIDC via Keycloak, conversation UX, request/response pipeline hooks |
| Agent/LLM telemetry | OpenTelemetry Collector | Receives spans/events from BeeAI + Open WebUI pipelines; routes to MongoDB |
| Shared memory | Valkey | BSD-licensed Redis fork (wire-compatible). Agent-namespaced via HTTP shim |
| Object store | MongoDB 8.2 | Per-agent databases, shared artifacts |
| Log collection | Fluent Bit | Tails stdout, routes to Mongo |
| Version control | Gitea | Self-hosted, stores skill documents |
| Reverse proxy / egress | Nginx | All agent outbound traffic |
| OIDC (human auth) | Keycloak | Human identity only, not agent identity |
| Gateway (future) | IBM API Connect + DataPower | Replaces/wraps Nginx in enterprise deploy |
| Human identity (future) | IBM Verify | Enterprise IBM identity integration |

---

## Architecture: Two-Layer Design

### Transparent Layer
Infrastructure the agent benefits from but never addresses directly. No agent awareness required.

- TLS and certificate rotation (Vault PKI)
- Log forwarding (Fluent Bit)
- Outbound HTTP proxying (Nginx)
- Vault token renewal (vault-agent embedded in agent container, managed by process supervisor)
- Credential rotation (Vault dynamic secrets)

### Conscious Layer
What agents know about, spelled out in their skill document (system prompt injection).

- Valkey shared memory (namespaced key conventions)
- MongoDB object store (per-agent database)
- Gitea VCS (for code agents)
- Nine agent tools (described below)
- Vault Transit (encrypt/decrypt via Tool #8 — never called directly by agents)

### Human + Runtime Layer
The human and execution surfaces are explicit and OSS:

- Open WebUI is the human-facing interface, backed by Keycloak OIDC for human authentication and access control.
- BeeAI Framework is the default agent runtime for orchestrators, workers, and sub-agents.
- Open WebUI pipelines and BeeAI telemetry emit LLM interaction audit events into OpenTelemetry Collector.
- OpenTelemetry Collector writes normalized LLM audit records into MongoDB (`garrison_audit.llm`).

---

## Agent Identity Model

Agents authenticate via **Vault AppRole**. Humans authenticate via Keycloak OIDC. These are intentionally separate identity systems.

**Agent provisioning flow:**
1. Terraform provisions an AppRole role per agent class with a scoped policy
2. At spawn time, provisioning script calls `vault write -f auth/approle/role/<name>/secret-id`
3. Agent authenticates with role-id + one-time secret-id → receives a scoped Vault token
4. Token TTL matches agent class definition (1h for RAG, 2h for code, 4h for orchestrator)
5. Embedded vault-agent process handles renewal transparently
6. On teardown, token is explicitly revoked; dynamic credentials expire

**CRITICAL:** Secret-ids are never stored in Terraform state. Role-ids are stable and safe to store.

---

## BeeAI + Open WebUI Integration

This project standardizes on:

- **BeeAI Framework** for agent execution, orchestration, and sub-agent lifecycle
- **Open WebUI** for human-facing sessions and Keycloak-backed access control

### Human Authentication and Session Boundary

- Humans authenticate to Open WebUI via Keycloak OIDC.
- Open WebUI issues/maintains human session context and forwards only authorized requests to tool-server.
- Open WebUI does not call BeeAI runtime directly. All runtime operations are routed through tool-server as the single policy chokepoint.
- Agent identity remains Vault AppRole-based and independent from human OIDC identity.

### Dynamic System Prompt Injection

- Garrison skill documents are rendered by `modules/agent-skill/` and stored in Gitea.
- At spawn time, tool-server resolves the skill document for the target class and injects it as the BeeAI system instruction payload.
- BeeAI class templates can append class-specific rules, but must not remove required Garrison constraints.

### Agent <-> LLM Access Control and Auditing

- BeeAI routes all model calls through configured provider adapters (Ollama, OpenAI-compatible, watsonx.ai, etc.).
- Open WebUI pipeline hooks capture human-facing request/response metadata.
- BeeAI emits tool/LLM spans and Open WebUI emits pipeline audit events to OpenTelemetry Collector.
- OpenTelemetry Collector normalizes and writes events to MongoDB `garrison_audit.llm`.
- `human_session_id` propagation is mandatory for every runtime call and sub-agent spawn. For autonomous jobs with no human origin, set `human_session_id="system:<job_id>"`.
- LLM payload logging mode is configurable (MVP-supported):
  - `full` — store full prompt/response bodies
  - `redacted` — store bodies with configured redaction rules applied
  - `hash-only` — store SHA-256 hashes and metadata only
- Configuration key: `GARRISON_AUDIT_PAYLOAD_MODE` (default: `full` for MVP).
- Minimum audit fields: `trace_id`, `agent_id`, `agent_class`, `human_session_id`, `model_provider`, `model_name`, `token_counts`, `tool_name` (nullable), `status`, `timestamp`.

---

## Vault Configuration (OpenTofu Modules)

### Module Execution Order

```
modules/
├── infra/           # Layer 0 — containers via Docker provider
├── vault-core/      # Layer 1 — audit devices, AppRole mount, Kubernetes auth mount
├── vault-pki/       # Layer 2 — root CA, intermediate CA, agent-mesh TLS role
├── vault-secrets/   # Layer 3 — MongoDB dynamic creds, Valkey KV + rotation
├── vault-transit/   # Layer 4 — encryption-as-a-service keyring
├── vault-policy/    # Layer 5 — HCL policy docs rendered per agent class
├── agent-role/      # Layer 6 — AppRole role per agent class (for_each)
└── agent-skill/     # Layer 7 — skill document rendered and committed to Gitea
```

### Agent Classes (defined in terraform.tfvars)

```hcl
agent_classes = {
  orchestrator = {
    capabilities = ["base", "orchestrate"]
    token_ttl    = "4h"
    description  = "Tier 1 query handler. Plans tool use, delegates, manages handoffs."
  }
  rag = {
    capabilities = ["base", "rag"]
    token_ttl    = "1h"
    description  = "Retrieval agent. Reads source docs, writes structured summaries."
  }
  code = {
    capabilities = ["base", "code"]
    token_ttl    = "2h"
    description  = "Code generation agent. Reads and commits to Gitea."
  }
  analyst = {
    capabilities = ["base"]
    token_ttl    = "1h"
    description  = "Read-only analysis. Reads shared memory, writes findings only."
  }
}
```

Adding a new agent type = one new block here. Terraform provisions the full stack.

### Vault Transit Keys

```hcl
keys = {
  agent-payload    = { type = "aes256-gcm96", convergent = false }
  shared-memory    = { type = "aes256-gcm96", convergent = true }   # deterministic for dedup
  artifact-signing = { type = "ed25519",       convergent = false }
}
```

### Vault Policy Capability Templates

Policies are composed by appending templates to a base:

- `base-agent.hcl.tpl` — all agents. Dynamic creds, own PKI cert, Transit encrypt/decrypt on agent-payload and shared-memory.
- `orchestrator.hcl.tpl` — adds: write handoff payloads, provision secret-ids for all agent classes (exercised by Spawn tool, Tool #9), read all role-ids.
- `rag-agent.hcl.tpl` — adds: MongoDB rag-writer role, broader Transit decrypt.
- `code-agent.hcl.tpl` — adds: Gitea token read, Transit sign/verify on artifact-signing key.

**Note on `analyst` class:** The `analyst` class uses `base-agent.hcl.tpl` exclusively — there is no `analyst.hcl.tpl`. The `vault-policy` module's `for_each` logic must handle agent classes that have no additive template (i.e., skip the append step rather than error). This must be tested explicitly.

---

## Vault Audit Configuration

Vault is the **audit spine** of the entire system. Register two audit devices in `vault-core`:

```hcl
resource "vault_audit" "file" {
  type = "file"
  options = {
    file_path = "/vault/logs/audit.log"
  }
}

resource "vault_audit" "syslog" {
  type = "syslog"
  options = {
    tag      = "garrison-vault"
    facility = "AUTH"
  }
}
```

Fluent Bit tails `/vault/logs/audit.log` and routes to MongoDB `garrison_audit` collection. Every secret access, credential generation, policy check, and auth attempt is captured with the requesting token identity. This is the source of truth for "what did agent X do."

**Correlation key:** `agent_id` is stamped on every Vault token at issuance via token metadata. All downstream log entries carry it.

---

## The Nine Agent Tools

These are HTTP endpoints the agent calls explicitly. Each is a thin service backed by the infrastructure layer. All calls pass through Nginx (logged) and require a valid Vault token (audited).

### 1. Semantic Search
- **Endpoint:** `POST /tools/search`
- **Backing:** `mongot` local vector index (MVP); MongoDB Atlas Vector Search (production path)
- **Input:** `{ query: string, corpus: string, top_k: int }`
- **Output:** `{ results: [{ id, score, summary, source }] }`
- **Purpose:** Query what agents have already learned before making external calls.

### 2. Shared Memory Read/Write
- **Endpoint:** `GET|POST|DELETE /tools/memory/{key}`
- **Backing:** Valkey via HTTP shim (NOT direct Valkey access)
- **Key enforcement:** Shim validates key against agent's namespacing policy
  - `agent:{agent_id}:*` — own private keys
  - `shared:memory:*` — cross-agent shared space
  - `registry:*` — read-only for non-orchestrators
- **Purpose:** Cross-agent coordination, reading orchestrator instructions, writing results.
- **NOTE:** The HTTP shim is mandatory. Agent containers have no network route to Valkey — enforcement is structural (`data-net` isolation), not policy-only.

### 3. Private Scratchpad
- **Endpoint:** `GET|POST|DELETE /tools/scratch/{key}`
- **Backing:** Valkey, agent-namespaced, TTL=1h auto-applied
- **Purpose:** Private working memory. Draft reasoning, intermediate state. Not visible to other agents.

### 4. Web Fetch
- **Endpoint:** `POST /tools/fetch`
- **Backing:** Nginx forward proxy
- **Input:** `{ url: string, method: string, headers: object }`
- **Output:** `{ status: int, body: string, content_type: string }`
- **Purpose:** External HTTP. All traffic logged by Nginx → Fluent Bit → MongoDB.

### 5. Document Summarize
- **Endpoint:** `POST /tools/summarize`
- **Backing:** Local small model (Phi-3 mini via Ollama)
- **Input:** `{ content: string, max_tokens: int, format: "bullets"|"prose"|"structured" }`
- **Output:** `{ summary: string, key_points: [string] }`
- **Purpose:** Reduce large documents to fit agent context. Summarization is local — no raw source content leaves the runtime.

### 6. Agent Registry Read
- **Endpoint:** `GET /tools/registry`
- **Backing:** Valkey hash `registry:agents`
- **Output:** `{ agents: [{ agent_id, class, status, capabilities, spawned_at }] }`
- **Purpose:** Orchestrators use this for delegation decisions.

### 7. Handoff Write
- **Endpoint:** `POST /tools/handoff`
- **Schema enforced — no freeform writes**
```json
{
  "from_agent_id": "string",
  "to_agent_class": "string",
  "task_context": "string",
  "artifacts": [{ "type": "string", "ref": "string" }],
  "memory_keys": ["string"],
  "reasoning_summary": "string",
  "priority": "low|normal|high"
}
```
- **Backing:** Writes to Valkey `registry:handoff:{from_agent_id}` + MongoDB `agent_{id}.handoffs`
- **Purpose:** Structured agent-to-agent task transfer. Schema is what makes handoffs reliable.

### 8. Vault Transit Encrypt/Decrypt
- **Endpoints:** `POST /tools/encrypt`, `POST /tools/decrypt`
- **Backing:** Vault Transit API — proxied by tool-server. Agents never call Vault directly.
- **Encrypt input:** `{ plaintext: string (base64), key: "agent-payload"|"shared-memory" }`
- **Encrypt output:** `{ ciphertext: string }`
- **Decrypt input:** `{ ciphertext: string, key: "agent-payload"|"shared-memory" }`
- **Decrypt output:** `{ plaintext: string (base64) }`
- **Purpose:** Encrypt payloads before writing to shared memory or external systems; decrypt on retrieval. All calls are dual-audited: Vault Transit operation log + tool-server stdout. Agents never hold Transit credentials — the tool-server exercises the Transit path using its own scoped token.

### 9. Spawn Agent
- **Endpoints:** `POST /tools/spawn`, `DELETE /tools/spawn/{agent_id}`
- **Access:** Orchestrator class only — enforced by tool-server middleware (`agent_class == "orchestrator"`). All other callers receive `403`.
- **Input:** `{ agent_class: string, task_context: string, memory_keys: ["string"] }`
- **Output:** `{ agent_id: string, status: "spawned"|"failed", error?: string }`
- **Flow (executed by tool-server):**
  1. Verify caller is `orchestrator` class
  2. Call Vault to generate a one-time secret-id for the requested agent class
  3. Provision MongoDB collections: `agent_{new_id}.objects`, `agent_{new_id}.handoffs`
  4. Resolve the BeeAI agent template for the requested class and inject the rendered Garrison skill document as the BeeAI system instruction
  5. Call BeeAI runtime spawn API to launch a new agent worker with `VAULT_ROLE_ID`, `VAULT_SECRET_ID`, and `GARRISON_SKILL_DOC` as runtime inputs
  6. BeeAI worker authenticates to Vault through embedded vault-agent and begins execution
  7. Write the new agent's entry to `registry:agents`
  8. Return `agent_id` to the calling orchestrator
- **Infrastructure requirement:** tool-server requires authenticated access to BeeAI runtime control API only. Direct container-runtime socket access is not required in this model.
- **ROKS upgrade path:** BeeAI runtime can back worker launch via Kubernetes API (`pods/create` scoped to garrison namespace). Tool-server contract remains unchanged.
- **Delete semantics (`DELETE /tools/spawn/{agent_id}`):**
  1. Verify caller is `orchestrator` class
  2. Verify target agent belongs to caller's active spawn tree
  3. Call BeeAI runtime terminate API for `agent_id`
  4. Revoke target Vault token
  5. Remove `registry:agents` entry
  6. Return `{ agent_id, status: "terminated"|"not_found"|"failed", error?: string }`
- **Audit requirement:** BeeAI runtime must attach `agent_id`, `agent_class`, and `human_session_id` on all LLM spans/events before exporting to OpenTelemetry Collector.


---

## Valkey Namespacing Conventions

The HTTP shim enforces these. Agents cannot write outside their allowed namespace.

```
agent:{agent_id}:state          # own ephemeral state (TTL 1h)
agent:{agent_id}:scratch:*      # own scratchpad (TTL 1h)
shared:memory:{key}             # cross-agent shared facts
registry:agents                 # active agent hash (orchestrator write, all read)
registry:handoff:{agent_id}     # handoff payload (write before yielding)
```

**`registry:agents` write responsibility:** Entries are created in two ways: (1) by the **provisioning script** for statically managed agents; (2) by **Tool #9 (Spawn)** for dynamically spawned agents. The orchestrator's write permission covers status updates on existing entries only — it cannot create or delete registry entries directly. Deletion on teardown is handled by `DELETE /tools/spawn/{agent_id}` for dynamic agents, or by the provisioning script for static agents.

---

## MongoDB Structure

```
# Per-agent (provisioned by Terraform at agent class creation)
agent_{agent_id}.objects        # general artifact storage
agent_{agent_id}.handoffs       # serialized handoff documents

# Shared (read-mostly)
shared_artifacts.objects        # cross-agent artifacts

# Audit and logging
garrison_audit.vault            # Vault audit log entries (via Fluent Bit)
garrison_audit.nginx            # Nginx access log entries (via Fluent Bit)
garrison_audit.llm              # BeeAI/Open WebUI LLM request-response audit events (via OTel Collector)
agent_logs.{agent_id}           # per-agent stdout/stderr (via Fluent Bit)
```

**Dynamic collection provisioning:** Collections for statically defined agent classes are provisioned by Terraform (`agent-role` module). For dynamically spawned agents (Tool #9), the spawn handler provisions `agent_{new_id}.objects` and `agent_{new_id}.handoffs` at spawn time using a dedicated MongoDB admin credential scoped to `agent_*` databases only. This credential must not have access to `garrison_audit` or `shared_artifacts`.

---

## Logging Pipeline

```
Agent stdout/stderr
        ↓
Fluent Bit (tails Podman socket)
        ↓
Tags with agent_id from container label: toolbox.agent_id
        ↓
MongoDB garrison_audit + agent_logs
  ↑
OpenTelemetry Collector (BeeAI spans + Open WebUI pipeline events)
        ↑
Vault audit.log (tailed separately)
        ↑
Nginx access.log (tailed separately)
```

**Unified query story:** All audit data lands in MongoDB with `agent_id` as the correlation key. A single MongoDB query across collections gives a complete picture of what an agent did, what it accessed, and what it called externally.

---

## Skill Document (System Prompt Injection)

Generated by `modules/agent-skill/` and committed to Gitea. Rendered from a template with real values substituted. Injected into every agent's system prompt at spawn time.

The skill document covers ONLY the conscious layer. It explicitly lists what the agent does NOT need to manage (transparent layer services).

Key sections:
- Agent identity (`agent_id`, `agent_class`)
- Nine tool endpoints with input/output schemas
- Valkey key conventions the agent is allowed to use
- MongoDB database name and collection conventions
- Gitea URL and token (code agents only)
- Vault Transit key names for encrypt/decrypt calls
- BeeAI runtime constraints (class-specific rules, tool allow-list, max steps)
- Explicit "you do not manage" list (TLS, logging, proxy, token refresh)

---

## Podman Compose Service List

```yaml
services:
  # data-net only — no agent container can route to these services
  valkey:       # shared memory, registry, scratchpad
  mongo:        # object store, handoffs, audit logs
  gitea:        # VCS for code agents and skill docs
  ollama:       # local model for summarization tool
  otel-collector: # receives BeeAI and Open WebUI telemetry; writes normalized events to mongo
  fluent-bit:   # log collection — tails Vault/Nginx logs and posts events to tool-server internal ingest

  # agent-net + data-net bridge
  tool-server:  # exposes nine tools to agents; the only bridge service across both networks
                # delegates dynamic agent spawn/terminate to BeeAI runtime API
  beeai-runtime: # BeeAI execution API/control-plane; reachable only from tool-server

  # agent-net
  vault:        # identity spine, secret engine, audit log
  nginx:        # egress proxy (external) and reverse proxy (tool-server routing)
  open-webui:   # human-facing UI; OIDC with Keycloak; pipeline hooks for LLM auditing

  # agent-dmz
  keycloak:     # human OIDC only
```

Agent containers are placed on `agent-net` only. They have no route to `data-net`. All access to Valkey, MongoDB, Gitea, and Ollama is mediated by tool-server. BeeAI runtime orchestrates agent execution. vault-agent runs inside each agent container as an embedded process — it is not a compose service.

### Agent Container Image
Every BeeAI worker image must include:
- BeeAI agent runtime process
- The `vault-agent` binary
- A process supervisor (`supervisord` recommended for MVP)

Startup sequence managed by the supervisor:
1. vault-agent starts first — reads `VAULT_ROLE_ID` + `VAULT_SECRET_ID` from env, completes AppRole auth, writes the resulting token to a shared `tmpfs` (e.g., `/vault/token`)
2. Agent process starts — reads token from `tmpfs`, uses it for all tool-server calls
3. vault-agent manages renewal for the container's lifetime

Credentials (`VAULT_ROLE_ID`, `VAULT_SECRET_ID`) are consumed at startup and never persisted to disk. The token on `tmpfs` is ephemeral and lost on container stop.

**ROKS upgrade path:** vault-agent becomes a proper K8s sidecar container sharing the Pod's volume. The supervisord model is dropped. The token `tmpfs` pattern remains unchanged.

### Networks
```yaml
networks:
  agent-net:
    # agent containers, vault, tool-server, nginx, open-webui
    # agents reach vault (AppRole auth via embedded vault-agent at startup)
    # agents reach nginx → tool-server for all tool calls
    # NO route to data-net exists from this network
  data-net:
    # valkey, mongodb, gitea, ollama, otel-collector, fluent-bit, tool-server, beeai-runtime
    # tool-server is the only bridge service between agent-net and data-net
    # data services are unreachable from agent-net at the network layer
  agent-dmz:
    # nginx, keycloak, open-webui — external-facing only
```

---

## The Tool Server (Primary Policy Gateway)

The `tool-server` is the main policy enforcement gateway between agents and data-plane services. It is a lightweight HTTP API that:

1. Validates the incoming Vault token against Vault's `/v1/auth/token/lookup-self`
2. Extracts `agent_id` and `agent_class` from the token metadata
3. Routes to the appropriate tool handler
4. Enforces namespacing rules (Valkey shim)
5. Returns structured JSON responses
6. Logs all calls to stdout (Fluent Bit picks them up)

**Suggested implementation:** Python + FastAPI or Go + chi. Stateless. Single binary or container.

**Endpoints to implement in order:**
1. `GET /health` — liveness check
2. `GET|POST /tools/scratch/{key}` — validates agent identity + namespaced Valkey
3. `GET|POST /tools/memory/{key}` — same pattern, different namespace rules
4. `GET /tools/registry` — read-only Valkey hash
5. `POST /tools/fetch` — Nginx-proxied HTTP
6. `POST /tools/handoff` — schema validation + dual write (Valkey + Mongo)
7. `POST /tools/summarize` — Ollama call
8. `POST /tools/encrypt` + `POST /tools/decrypt` — Vault Transit proxy
9. `POST /tools/spawn` — dynamic agent provisioning via BeeAI runtime API (orchestrator class only)
10. `DELETE /tools/spawn/{agent_id}` — dynamic agent teardown via BeeAI runtime API (orchestrator class only)
11. `POST /tools/search` — MongoDB vector query (implement last, requires index setup)
12. `POST /orchestrate` — user-request orchestration entrypoint that may invoke `POST /tools/spawn` internally (policy-mediated only)

### Planned Orchestration Bridge (Next Increment)

Add a minimal orchestration bridge so Open WebUI user actions do not call spawn directly.

Proposed contract:
- Endpoint: `POST /orchestrate`
- Input:
```json
{
  "request_text": "string",
  "human_session_id": "string",
  "preferred_agent_class": "orchestrator|code|rag|analyst (optional)"
}
```
- Output:
```json
{
  "workflow_id": "string",
  "status": "accepted|completed|failed",
  "spawned_agent_id": "string|null",
  "result_summary": "string"
}
```

Rules:
1. Only tool-server may invoke `POST /tools/spawn`.
2. Existing spawn controls remain authoritative (orchestrator-only, depth cap, spawn-tree ownership).
3. `human_session_id` must be propagated to spawn, handoff, and audit events for end-to-end traceability.
4. Open WebUI pipeline should call `/orchestrate` for delegated tasks and continue to emit inlet/outlet audit events.

---

## OpenTofu / Terraform Providers Required

```hcl
terraform {
  required_providers {
    vault  = { source = "hashicorp/vault",        version = "~> 4.0" }
    docker = { source = "kreuzwerker/docker",     version = "~> 3.0" }  # swap for kubernetes on ROKS
    gitea  = { source = "gitea/gitea",            version = "~> 0.5" }
    local  = { source = "hashicorp/local",        version = "~> 2.0" }
    null   = { source = "hashicorp/null",         version = "~> 3.0" }
  }
}
```

---

## Build Order for MVP

1. **`compose.yaml`** — get all services up and healthy
2. **`modules/infra/`** — Terraform wrapping the same compose setup
3. **`modules/vault-core/`** — audit devices, AppRole mount
4. **`modules/vault-pki/`** — internal CA, agent-mesh TLS
5. **`modules/vault-secrets/`** — MongoDB and Valkey dynamic credentials
6. **`modules/vault-transit/`** — three Transit keys
7. **`modules/vault-policy/`** — policy templates rendered per class
8. **`modules/agent-role/`** — AppRole roles via for_each
9. **`beeai-runtime/`** — class templates, spawn/terminate API, OTel instrumentation
10. **`open-webui/`** — Keycloak OIDC integration + pipeline hooks for LLM audit events
11. **`config/otel/`** — collector pipeline to MongoDB `garrison_audit.llm`
12. **`tool-server`** — the nine tools, implement in order listed above
13. **`modules/agent-skill/`** — skill document generation and Gitea commit
14. **Provisioning script** — base bootstrap flow:
    1. Generate a one-time secret-id: `vault write -f auth/approle/role/<class>/secret-id`
    2. Fetch the rendered skill document from Gitea by agent class slug
  3. Start the BeeAI worker with `VAULT_ROLE_ID`, `VAULT_SECRET_ID`, and `GARRISON_SKILL_DOC` injected as runtime environment variables (never written to disk)
    4. The embedded vault-agent process inside the container completes AppRole authentication at startup, writes the token to a shared `tmpfs`, and manages renewal for the container's lifetime. No companion container is needed.
    5. Write the agent's entry into `registry:agents` Valkey hash: `{ agent_id, class, status: "active", capabilities, spawned_at }`
    6. On teardown: explicitly revoke the Vault token (`vault token revoke <token>`), stop the agent container (vault-agent process terminates with it), remove the entry from `registry:agents`

---

## File Structure

```
garrison/
├── compose.yaml
├── .env.example
├── config/
│   ├── fluent-bit/
│   │   ├── fluent-bit.conf
│   │   └── parsers.conf
│   ├── nginx/
│   │   ├── nginx.conf
│   │   └── conf.d/
│   ├── otel/
│   │   └── collector.yaml
│   └── vault/
│       └── vault.hcl
├── terraform/
│   ├── main.tf
│   ├── variables.tf
│   ├── outputs.tf
│   ├── versions.tf
│   ├── terraform.tfvars.example
│   └── modules/
│       ├── infra/
│       ├── vault-core/
│       ├── vault-pki/
│       ├── vault-secrets/
│       ├── vault-transit/
│       ├── vault-policy/
│       │   └── templates/
│       │       ├── base-agent.hcl.tpl
│       │       ├── orchestrator.hcl.tpl
│       │       ├── rag-agent.hcl.tpl
│       │       └── code-agent.hcl.tpl
│       ├── agent-role/
│       └── agent-skill/
│           └── templates/
│               └── skill.md.tpl
├── tool-server/
│   ├── main.py              # or main.go
│   ├── routers/
│   │   ├── memory.py
│   │   ├── scratch.py
│   │   ├── registry.py
│   │   ├── fetch.py
│   │   ├── handoff.py
│   │   ├── summarize.py
│   │   ├── transit.py       # encrypt + decrypt (Tool #8)
│   │   ├── spawn.py         # dynamic agent provisioning (Tool #9, orchestrator only)
│   │   └── search.py
│   ├── middleware/
│   │   └── vault_auth.py    # token validation + agent_id extraction
│   └── Containerfile
├── beeai-runtime/
│   ├── src/
│   │   ├── templates/       # class templates: orchestrator/rag/code/analyst
│   │   ├── spawn.ts         # spawn + terminate API handlers
│   │   └── telemetry.ts     # OpenTelemetry export + required audit tags
│   └── Containerfile
├── open-webui/
│   └── pipelines/
│       └── garrison_audit.py # pipeline hook for request/response metadata
├── scripts/
│   └── provision-agent.sh   # bootstrap flow: secret-id → auth → inject skill
└── skills/
    └── (generated by Terraform, committed to Gitea)
```

---

## OSS Constraints to Document

The following require Vault Enterprise and should be noted as upgrade paths for client conversations:

- **Vault Namespaces** — true multi-tenant isolation. OSS uses path-based isolation enforced by ACL policy. Sufficient for single-client deployments.
- **Sentinel policies** — logic-based policy enforcement (e.g., "deny if token TTL > 2h"). OSS enforces at provisioning layer instead.
- **Vault Replication** — HA multi-cluster. OSS is single cluster.
- **Transform engine** — format-preserving encryption for regulated data fields.

The following are OSS licensing constraints for the base stack:

- **Redis licensing** — Redis 7.4+ ships under SSPL/RSALv2, which is not an OSS-compatible license. **Use Valkey instead** — the BSD-licensed Linux Foundation fork branched from Redis 7.2. The API is wire-compatible; no tool-server or application code changes are required. Update `compose.yaml` and the stack table to reference Valkey.

---

## IBM Integration Notes (Future / Enterprise Path)

- **DataPower** replaces Nginx in enterprise deployment. Provides full transaction capture, JWT validation at wire level, and hardware-backed crypto. All agent tool calls pass through it. Correlation IDs stamped at ingress.
- **API Connect** models each agent tool as a managed API — versioned, documented, quota-enforced. Developer portal becomes the authoritative skill document source.
- **IBM Verify** handles human identity at the perimeter. Keycloak is the OSS stand-in.
- **ROKS** is the OpenShift target. `podman generate kube` produces K8s manifests from compose. `modules/infra/` swaps from Docker provider to Kubernetes provider. Everything else is unchanged.
- **Vault Kubernetes auth** is already scaffolded in `vault-core`. No redesign needed for the ROKS move.

---

## Non-Goals for MVP

- Building a custom agent framework (BeeAI is adopted as the runtime)
- Building a custom chat UI (Open WebUI is adopted for the human-facing layer)
- Multi-cluster Vault
- IBM API Connect integration
- DataPower integration
- File system access for agents (use object store)
- Agent-to-agent direct communication (use Valkey shared memory + handoff tool)
