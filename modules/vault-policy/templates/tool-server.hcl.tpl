# tool-server.hcl.tpl — Policy for the tool-server service identity.
# Applied to: the tool-server process (not an agent class).
# tool-server is the ONLY bridge between agent-net and data-net.
# It proxies Vault Transit operations and manages agent spawn/teardown.
#
# Deliberately excludes:
#   - sys/auth management (handled by bootstrap / terraform, not runtime)
#   - sys/mounts management (same)
#   - Any path not required for runtime tool-server operations

# Read stable role-ids (needed to construct spawn payload for BeeAI)
path "auth/approle/role/+/role-id" {
  capabilities = ["read"]
}

# Generate one-time secret-ids (spawn path — called by POST /tools/spawn)
path "auth/approle/role/+/secret-id" {
  capabilities = ["update"]
}

# Perform AppRole authentication on behalf of spawn flow
path "auth/approle/login" {
  capabilities = ["create", "update"]
}

# Revoke agent tokens on teardown (DELETE /tools/spawn/{agent_id})
path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}

# Transit encrypt/decrypt proxy — agents call tool-server, tool-server calls Vault.
# Agents never hold Transit credentials directly.
path "transit/encrypt/agent-payload" {
  capabilities = ["update"]
}
path "transit/decrypt/agent-payload" {
  capabilities = ["update"]
}
path "transit/encrypt/shared-memory" {
  capabilities = ["update"]
}
path "transit/decrypt/shared-memory" {
  capabilities = ["update"]
}
