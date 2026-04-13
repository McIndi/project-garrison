# API Reference

## Auth Headers

Most tool-server runtime endpoints require:

- Authorization: Bearer <token>
- x-agent-id
- x-agent-class
- x-human-session-id (optional; system id generated when absent)
- x-spawn-depth
- x-root-orchestrator-id (required for nested spawn depth)

## Endpoints

| Endpoint | Method | Purpose |
|---|---|---|
| /health | GET | Service health |
| /tools/memory/{key} | GET/POST/DELETE | Shared or private memory keys under enforced namespace |
| /tools/scratch/{key} | GET/POST/DELETE | Private scratch namespace with TTL |
| /tools/registry | GET | List active registry agents |
| /tools/fetch | POST | Controlled HTTP fetch |
| /tools/handoff | POST | Write handoff payload |
| /tools/summarize | POST | Extractive or ollama-backed summarize |
| /tools/encrypt | POST | Vault transit encrypt (agent-payload/shared-memory keys) |
| /tools/decrypt | POST | Vault transit decrypt (agent-payload/shared-memory keys) |
| /tools/search | POST | Corpus search in Mongo-backed documents |
| /orchestrate | POST | Human request orchestration bridge |
| /tools/spawn | POST | Spawn new delegated agent |
| /tools/spawn/{agent_id} | DELETE | Terminate delegated agent |

## Orchestration Request

POST /orchestrate body:

- request_text: string
- human_session_id: string
- preferred_agent_class: orchestrator | code | rag | analyst (optional)

Response includes:

- workflow_id
- status: accepted | completed | failed
- spawned_agent_id (when delegation occurs)
- result_summary

## Spawn Constraints

- Only x-agent-class=orchestrator may spawn or terminate.
- Spawn depth is capped by TOOL_SERVER_SPAWN_MAX_DEPTH.
- root_orchestrator_id ownership is enforced on terminate.
