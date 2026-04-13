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

api_post_optional() {
  local path="$1"
  local payload="$2"
  if ! curl -fsS -X POST -H "X-Vault-Token: ${VAULT_TOKEN}" -H "Content-Type: application/json" \
    -d "${payload}" "${VAULT_ADDR}${path}" >/dev/null 2>&1; then
    echo "[WARN] Optional Vault config step failed: ${path}"
  fi
}

api_put() {
  local path="$1"
  local payload="$2"
  curl -fsS -X PUT -H "X-Vault-Token: ${VAULT_TOKEN}" -H "Content-Type: application/json" \
    -d "${payload}" "${VAULT_ADDR}${path}" >/dev/null
}

put_policy() {
  local name="$1"
  local policy_text="$2"
  local escaped
  escaped="$(printf '%s' "${policy_text}" | sed ':a;N;$!ba;s/\n/\\n/g;s/"/\\"/g')"
  api_put "/v1/sys/policies/acl/${name}" "{\"policy\":\"${escaped}\"}"
}

echo "Configuring Vault baseline (audit, transit, approle, policies, roles, database)..."

# Enable file audit device if not already present.
if ! api_get "/v1/sys/audit" | grep -q '"file/"'; then
  api_post "/v1/sys/audit/file" '{"type":"file","options":{"file_path":"/vault/logs/audit.log"}}'
fi

# Enable AppRole auth mount if not already present.
if ! api_get "/v1/sys/auth" | grep -q '"approle/"'; then
  api_post "/v1/sys/auth/approle" '{"type":"approle"}'
fi

# Enable transit engine if not already present.
if ! api_get "/v1/sys/mounts" | grep -q '"transit/"'; then
  api_post "/v1/sys/mounts/transit" '{"type":"transit"}'
fi

# Enable database engine for dynamic database credentials.
if ! api_get "/v1/sys/mounts" | grep -q '"database/"'; then
  api_post "/v1/sys/mounts/database" '{"type":"database"}'
fi

# Ensure transit keys exist.
api_post "/v1/transit/keys/agent-payload" '{"type":"aes256-gcm96"}' || true
api_post "/v1/transit/keys/shared-memory" '{"type":"aes256-gcm96"}' || true
api_post "/v1/transit/keys/artifact-signing" '{"type":"ed25519"}' || true

# Base policy for all classes.
put_policy "garrison-base" 'path "transit/encrypt/agent-payload" {
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
path "database/creds/mongo-readonly" {
  capabilities = ["read"]
}
path "database/creds/valkey-readonly" {
  capabilities = ["read"]
}'

# Class additive policies.
put_policy "garrison-orchestrator" 'path "auth/approle/role/*/secret-id" {
  capabilities = ["update"]
}
path "auth/approle/role/*/role-id" {
  capabilities = ["read"]
}'

put_policy "garrison-rag" 'path "database/creds/mongo-rag-writer" {
  capabilities = ["read"]
}'

put_policy "garrison-code" 'path "database/creds/mongo-code-writer" {
  capabilities = ["read"]
}
path "transit/sign/artifact-signing" {
  capabilities = ["update"]
}
path "transit/verify/artifact-signing" {
  capabilities = ["update"]
}'

# Database connection and role definitions (best effort in dev).
api_post_optional "/v1/database/config/mongo" '{"plugin_name":"mongodb-database-plugin","allowed_roles":"mongo-readonly,mongo-rag-writer,mongo-code-writer","connection_url":"mongodb://{{username}}:{{password}}@mongo:27017/admin?authSource=admin","username":"root","password":"rootpass","verify_connection":false}'

api_post_optional "/v1/database/roles/mongo-readonly" '{"db_name":"mongo","creation_statements":"{\"db\":\"admin\",\"roles\":[{\"role\":\"read\",\"db\":\"admin\"}]}","default_ttl":"1h","max_ttl":"24h"}'
api_post_optional "/v1/database/roles/mongo-rag-writer" '{"db_name":"mongo","creation_statements":"{\"db\":\"admin\",\"roles\":[{\"role\":\"readWrite\",\"db\":\"admin\"}]}","default_ttl":"1h","max_ttl":"24h"}'
api_post_optional "/v1/database/roles/mongo-code-writer" '{"db_name":"mongo","creation_statements":"{\"db\":\"admin\",\"roles\":[{\"role\":\"readWrite\",\"db\":\"admin\"}]}","default_ttl":"1h","max_ttl":"24h"}'

api_post_optional "/v1/database/config/valkey" '{"plugin_name":"redis-database-plugin","allowed_roles":"valkey-readonly","host":"valkey","port":6379,"username":"default","password":"rootpass","verify_connection":false}'
api_post_optional "/v1/database/roles/valkey-readonly" '{"db_name":"valkey","creation_statements":"[\"~*\",\"+@read\"]","default_ttl":"1h","max_ttl":"24h"}'

# Ensure core roles exist with TTL and policy assignment.
api_post "/v1/auth/approle/role/orchestrator" '{"token_ttl":"4h","token_max_ttl":"4h","secret_id_num_uses":1,"secret_id_ttl":"30m","token_policies":["default","garrison-base","garrison-orchestrator"]}'
api_post "/v1/auth/approle/role/code" '{"token_ttl":"2h","token_max_ttl":"2h","secret_id_num_uses":1,"secret_id_ttl":"30m","token_policies":["default","garrison-base","garrison-code"]}'
api_post "/v1/auth/approle/role/rag" '{"token_ttl":"1h","token_max_ttl":"1h","secret_id_num_uses":1,"secret_id_ttl":"30m","token_policies":["default","garrison-base","garrison-rag"]}'
api_post "/v1/auth/approle/role/analyst" '{"token_ttl":"1h","token_max_ttl":"1h","secret_id_num_uses":1,"secret_id_ttl":"30m","token_policies":["default","garrison-base"]}'

echo "Vault baseline configured."
