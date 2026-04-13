# Architecture

## Service Topology

```mermaid
flowchart TB
    subgraph agent-net
      OW[Open WebUI]
      TS[tool-server]
      KC[Keycloak]
      VA[Vault]
    end

    subgraph data-net
      TS2[tool-server]
      BR[beeai-runtime]
      VA2[Vault]
      NX[Nginx]
      FB[Fluent Bit]
      VK[Valkey]
      MG[MongoDB]
      OT[OTel Collector]
    end

    User((User)) --> OW
    OW --> TS
    TS --> BR
    TS --> NX
    TS --> VK
    TS --> MG
    TS --> VA
    VA --> FB
    NX --> FB
    FB --> TS
    OW -. planned telemetry wiring .-> OT
    TS -. planned telemetry wiring .-> OT
```

## Runtime Responsibilities

- Open WebUI:
  - Human request entry point.
  - Pipeline hook that can call POST /orchestrate.
- tool-server:
  - Auth and policy enforcement.
  - Memory/scratch/search/fetch/summarize/encrypt/decrypt/handoff APIs.
  - Spawn and terminate governance.
  - Audit event emission.
- beeai-runtime (stub):
  - Spawn and terminate handlers with in-memory agent map.
- Vault:
  - Token lookup, AppRole role/secret issuance, transit operations.
- Nginx:
  - Outbound fetch proxy used by tool-server.
- Fluent Bit:
  - Tails Vault audit and Nginx access logs.
  - Forwards records to tool-server internal ingest endpoints.
- Valkey:
  - Shared memory and registry data.
- MongoDB:
  - Stores tool-server audit events and ingested Vault/Nginx logs.
- OTel Collector:
  - Deployed in compose and configured with OTLP receiver plus debug exporter.
  - tool-server audit middleware emits OTLP logs to collector.

## Design Constraints Enforced in Code

- Runtime requests require agent headers and bearer token.
- Orchestrator-only spawn/terminate.
- Spawn depth limit and root orchestrator lineage checks.
- human_session_id propagation across orchestration path.
