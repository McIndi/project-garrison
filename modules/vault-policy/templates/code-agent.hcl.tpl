# code-agent.hcl.tpl — Additive policy for the code generation agent class.
# Applied to: code (in addition to garrison-base).
# Grants: MongoDB readWrite credential + Transit sign/verify on artifact-signing key.

# Dynamic MongoDB code-writer credential (can write to code agent databases)
path "database/creds/mongo-code-writer" {
  capabilities = ["read"]
}

# Transit sign — sign git commits and code artifacts with ed25519 key
path "transit/sign/artifact-signing" {
  capabilities = ["update"]
}

# Transit verify — verify artifact signatures
path "transit/verify/artifact-signing" {
  capabilities = ["update"]
}
