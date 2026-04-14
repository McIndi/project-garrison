# rag-agent.hcl.tpl — Additive policy for the RAG (retrieval) agent class.
# Applied to: rag (in addition to garrison-base).
# Grants: MongoDB readWrite credential for rag-specific writes + broader Transit decrypt.

# Dynamic MongoDB rag-writer credential (broader than readonly — can write summaries)
path "database/creds/mongo-rag-writer" {
  capabilities = ["read"]
}

# Additional Transit decrypt for reading encrypted payloads from shared memory
path "transit/decrypt/agent-payload" {
  capabilities = ["update"]
}
