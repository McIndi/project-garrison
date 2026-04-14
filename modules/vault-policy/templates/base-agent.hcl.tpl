# base-agent.hcl.tpl — Garrison base policy for all agent classes.
# Applied to: orchestrator, rag, code, analyst.
# Grants: transit encrypt/decrypt on shared keys + dynamic DB credential reads.

# Transit encryption — encrypt agent payloads before writing to shared memory or external systems
path "transit/encrypt/agent-payload" {
  capabilities = ["update"]
}
path "transit/decrypt/agent-payload" {
  capabilities = ["update"]
}

# Transit encryption — shared memory keys (convergent for dedup)
path "transit/encrypt/shared-memory" {
  capabilities = ["update"]
}
path "transit/decrypt/shared-memory" {
  capabilities = ["update"]
}

# Dynamic MongoDB read-only credential (issued per-session, TTL 1h)
path "database/creds/mongo-readonly" {
  capabilities = ["read"]
}

# Dynamic Valkey read-only credential
path "database/creds/valkey-readonly" {
  capabilities = ["read"]
}

# Allow agents to look up their own token (required for tool-server identity binding)
path "auth/token/lookup-self" {
  capabilities = ["read"]
}
