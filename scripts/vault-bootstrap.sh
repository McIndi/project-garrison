#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"

api_get() {
  local path="$1"
  curl -fsS -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}${path}"
}

api_post() {
  local path="$1"
  local payload="$2"
  curl -fsS -X POST -H "X-Vault-Token: ${VAULT_TOKEN}" -H "Content-Type: application/json" \
    -d "${payload}" "${VAULT_ADDR}${path}" >/dev/null
}

echo "Configuring Vault baseline (audit, transit, approle, policies, roles)..."

# Enable file audit device if not already present.
if ! api_get "/v1/sys/audit" | grep -q '"file/"'; then
  api_post "/v1/sys/audit/file" '{"type":"file","options":{"file_path":"/tmp/garrison-vault-audit.log"}}'
fi

# Enable AppRole auth mount if not already present.
if ! api_get "/v1/sys/auth" | grep -q '"approle/"'; then
  api_post "/v1/sys/auth/approle" '{"type":"approle"}'
fi

# Enable transit engine if not already present.
if ! api_get "/v1/sys/mounts" | grep -q '"transit/"'; then
  api_post "/v1/sys/mounts/transit" '{"type":"transit"}'
fi

# Ensure transit keys exist.
api_post "/v1/transit/keys/agent-payload" '{"type":"aes256-gcm96"}' || true
api_post "/v1/transit/keys/shared-memory" '{"type":"aes256-gcm96"}' || true
api_post "/v1/transit/keys/artifact-signing" '{"type":"ed25519"}' || true

# Ensure core roles exist with TTL and policy assignment.
api_post "/v1/auth/approle/role/orchestrator" '{"token_ttl":"4h","token_max_ttl":"4h","secret_id_num_uses":1,"secret_id_ttl":"30m","token_policies":["default"]}'
api_post "/v1/auth/approle/role/code" '{"token_ttl":"2h","token_max_ttl":"2h","secret_id_num_uses":1,"secret_id_ttl":"30m","token_policies":["default"]}'
api_post "/v1/auth/approle/role/rag" '{"token_ttl":"1h","token_max_ttl":"1h","secret_id_num_uses":1,"secret_id_ttl":"30m","token_policies":["default"]}'
api_post "/v1/auth/approle/role/analyst" '{"token_ttl":"1h","token_max_ttl":"1h","secret_id_num_uses":1,"secret_id_ttl":"30m","token_policies":["default"]}'

echo "Vault baseline configured."
