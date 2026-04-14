# orchestrator.hcl.tpl — Additive policy for the orchestrator agent class.
# Applied to: orchestrator (in addition to garrison-base).
# Grants: secret-id generation for all agent classes + role-id reads (for spawn tool).

# Generate one-time secret-ids for any agent class (exercised by Tool #9 — Spawn).
# secret_id_num_uses=1 is enforced at role creation; this policy permits triggering issuance.
path "auth/approle/role/+/secret-id" {
  capabilities = ["update"]
}

# Read stable role-ids for all agent classes (needed to construct AppRole login payload).
path "auth/approle/role/+/role-id" {
  capabilities = ["read"]
}

# Write handoff payloads to shared memory (orchestrator-to-worker task transfer)
path "transit/encrypt/agent-payload" {
  capabilities = ["update"]
}
