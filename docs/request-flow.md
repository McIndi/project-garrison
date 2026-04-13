# Request Flow

## Human Request to Delegated Agent

```mermaid
sequenceDiagram
    participant User
    participant OW as Open WebUI Pipeline
    participant TS as tool-server
    participant VA as Vault
    participant BR as beeai-runtime
    participant NX as Nginx
    participant FB as Fluent Bit
    participant VK as Valkey
    participant MG as MongoDB
    participant OT as OTel Collector

    User->>OW: Ask for task execution
    OW->>OT: OTLP log emit (inlet)
    OW->>TS: POST /orchestrate
    Note over OW,TS: Headers include bearer + agent identity + human_session_id

    TS->>VA: auth/token/lookup-self
    VA-->>TS: token valid

    TS->>VA: read role-id + create secret-id + approle login
    VA-->>TS: role_id, secret_id, accessor

    TS->>BR: POST /spawn (class, context, ids, vault creds)
    BR-->>TS: agent_id spawned

    TS->>NX: POST /tools/fetch proxied request (when used)
    NX-->>TS: upstream response

    TS->>VK: registry_upsert(agent metadata)
    TS->>MG: create agent collections and write tool-server audit events
    VA->>FB: append audit.log entries
    NX->>FB: append access.log entries
    FB->>TS: POST /internal/audit/ingest/{vault|nginx}
    TS->>MG: persist ingested vault/nginx audit documents
    TS->>OT: OTLP log emit (tool-server audit middleware)

    TS-->>OW: workflow_id + spawned_agent_id + status
    OW->>OT: OTLP log emit (outlet)
    OW-->>User: accepted / completed response
```

## Termination Flow

```mermaid
sequenceDiagram
    participant TS as tool-server
    participant BR as beeai-runtime
    participant VA as Vault
    participant VK as Valkey

    TS->>VK: registry_get_record(agent_id)
    TS->>BR: POST /terminate
    BR-->>TS: terminated
    TS->>VA: revoke-accessor
    TS->>VK: registry_delete(agent_id)
```

## Failure Behavior

- If token lookup fails, request returns 401.
- If caller is not orchestrator for spawn/delete/orchestrate, request returns 403.
- If spawn depth exceeds configured max depth, request returns 403.
- Open WebUI pipeline orchestration errors are non-fatal to the UI request and captured in metadata.
