#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GARRISON_TERRAFORM="${GARRISON_TERRAFORM:-false}"
GARRISON_TERRAFORM_CONTAINER="${GARRISON_TERRAFORM_CONTAINER:-${CI:-false}}"
GARRISON_TERRAFORM_IMAGE="${GARRISON_TERRAFORM_IMAGE:-hashicorp/terraform:1.12.1}"

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"

resolve_compose_runtime() {
  if command -v docker >/dev/null 2>&1; then
    RUNTIME_ENGINE="docker"
    COMPOSE_CMD=(docker compose)
    return 0
  fi

  if command -v podman >/dev/null 2>&1; then
    RUNTIME_ENGINE="podman"
    COMPOSE_CMD=(podman compose)
    return 0
  fi

  return 1
}

resolve_vault_network() {
  local vault_container_id networks

  vault_container_id="$("${COMPOSE_CMD[@]}" -f "${ROOT_DIR}/compose.yaml" ps -q vault 2>/dev/null || true)"
  if [[ -z "${vault_container_id}" ]]; then
    echo "[ERROR] Unable to resolve vault container id from compose." >&2
    return 1
  fi

  networks="$("${RUNTIME_ENGINE}" inspect -f '{{range $k, $_ := .NetworkSettings.Networks}}{{println $k}}{{end}}' "${vault_container_id}" 2>/dev/null | sed '/^$/d' || true)"
  if [[ -z "${networks}" ]]; then
    echo "[ERROR] Unable to resolve compose network for vault container ${vault_container_id}." >&2
    return 1
  fi

  if grep -q 'data-net$' <<<"${networks}"; then
    VAULT_NETWORK="$(grep 'data-net$' <<<"${networks}" | head -n1)"
  elif grep -q 'agent-net$' <<<"${networks}"; then
    VAULT_NETWORK="$(grep 'agent-net$' <<<"${networks}" | head -n1)"
  else
    VAULT_NETWORK="$(head -n1 <<<"${networks}")"
  fi

  if [[ -z "${VAULT_NETWORK}" ]]; then
    echo "[ERROR] Computed Vault network is empty." >&2
    return 1
  fi

  return 0
}

run_terraform_in_container() {
  local mongo_root_password valkey_password
  mongo_root_password="${MONGO_ROOT_PASSWORD:-rootpass}"
  valkey_password="${VALKEY_PASSWORD:-rootpass}"

  echo "[Vault bootstrap] Containerized Terraform enabled (image=${GARRISON_TERRAFORM_IMAGE}, network=${VAULT_NETWORK})."

  "${RUNTIME_ENGINE}" run --rm \
    --network "${VAULT_NETWORK}" \
    -e TF_IN_AUTOMATION=1 \
    -e VAULT_ADDR="http://vault:8200" \
    -e VAULT_TOKEN="${VAULT_TOKEN}" \
    -e TF_VAR_mongo_root_password="${mongo_root_password}" \
    -e TF_VAR_valkey_password="${valkey_password}" \
    -v "${ROOT_DIR}:/workspace" \
    -w /workspace \
    "${GARRISON_TERRAFORM_IMAGE}" \
    -chdir=terraform init -backend=false

  "${RUNTIME_ENGINE}" run --rm \
    --network "${VAULT_NETWORK}" \
    -e TF_IN_AUTOMATION=1 \
    -e VAULT_ADDR="http://vault:8200" \
    -e VAULT_TOKEN="${VAULT_TOKEN}" \
    -e TF_VAR_mongo_root_password="${mongo_root_password}" \
    -e TF_VAR_valkey_password="${valkey_password}" \
    -v "${ROOT_DIR}:/workspace" \
    -w /workspace \
    "${GARRISON_TERRAFORM_IMAGE}" \
    -chdir=terraform apply -auto-approve
}

if [[ "${GARRISON_TERRAFORM}" == "true" ]]; then
  if [[ "${GARRISON_TERRAFORM_CONTAINER}" == "true" ]]; then
    if ! resolve_compose_runtime; then
      echo "[ERROR] GARRISON_TERRAFORM_CONTAINER=true but neither docker nor podman compose is available." >&2
      exit 1
    fi

    if ! resolve_vault_network; then
      exit 1
    fi

    run_terraform_in_container
  else
    if command -v tofu >/dev/null 2>&1; then
      TF_BIN="tofu"
    elif command -v terraform >/dev/null 2>&1; then
      TF_BIN="terraform"
    else
      echo "[ERROR] GARRISON_TERRAFORM=true but neither 'tofu' nor 'terraform' is available." >&2
      exit 1
    fi

    echo "[Vault bootstrap] Terraform mode enabled. Running ${TF_BIN} apply for Vault baseline..."
    export VAULT_ADDR
    export VAULT_TOKEN

    "${TF_BIN}" -chdir="${ROOT_DIR}/terraform" init -backend=false
    "${TF_BIN}" -chdir="${ROOT_DIR}/terraform" apply -auto-approve \
      -var="mongo_root_password=${MONGO_ROOT_PASSWORD:-rootpass}" \
      -var="valkey_password=${VALKEY_PASSWORD:-rootpass}"
  fi

  echo "[Vault bootstrap] Terraform apply completed."
  exit 0
fi

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

# Service identity for the tool-server process itself.
# Scoped to exactly the Vault operations tool-server performs at runtime:
# spawn-credential issuance, agent token revocation, and transit encryption.
# Root-level capabilities (sys/auth management, sys/mounts) are intentionally absent;
# bootstrap.sh is responsible for ensuring those are in place before the service starts.
put_policy "garrison-tool-server" 'path "auth/approle/role/+/role-id" {
  capabilities = ["read"]
}
path "auth/approle/role/+/secret-id" {
  capabilities = ["update"]
}
path "auth/approle/login" {
  capabilities = ["create", "update"]
}
path "auth/token/revoke-accessor" {
  capabilities = ["update"]
}
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
