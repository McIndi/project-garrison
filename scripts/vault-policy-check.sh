#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"

fail() {
  echo "[FAIL] $1"
  exit 1
}

ok() {
  echo "[OK] $1"
}

api_get_root() {
  local path="$1"
  curl -fsS -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}${path}"
}

api_post_root() {
  local path="$1"
  local payload="$2"
  local payload_file
  payload_file="$(mktemp /tmp/garrison-vault-policy-post.XXXXXX.json)"
  printf '%s' "${payload}" >"${payload_file}"
  curl -fsS -X POST -H "X-Vault-Token: ${VAULT_TOKEN}" -H "Content-Type: application/json" \
    --data-binary "@${payload_file}" "${VAULT_ADDR}${path}"
  rm -f "${payload_file}"
}

lookup_policies_json() {
  local client_token="$1"
  curl -fsS -H "X-Vault-Token: ${client_token}" "${VAULT_ADDR}/v1/auth/token/lookup-self"
}

spawn_role_token() {
  local role="$1"
  local role_id_json secret_id_json role_id secret_id login_json token login_payload_file

  role_id_json="$(api_get_root "/v1/auth/approle/role/${role}/role-id")"
  role_id="$(echo "${role_id_json}" | sed -n 's/.*"role_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [[ -n "${role_id}" ]] || fail "Failed to parse role_id for ${role}"

  secret_id_json="$(api_post_root "/v1/auth/approle/role/${role}/secret-id" '{}')"
  secret_id="$(echo "${secret_id_json}" | sed -n 's/.*"secret_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [[ -n "${secret_id}" ]] || fail "Failed to parse secret_id for ${role}"

  login_payload_file="$(mktemp /tmp/garrison-vault-login.XXXXXX.json)"
  printf '{"role_id":"%s","secret_id":"%s"}' "${role_id}" "${secret_id}" >"${login_payload_file}"
  login_json="$(curl -fsS -X POST -H "Content-Type: application/json" \
    --data-binary "@${login_payload_file}" \
    "${VAULT_ADDR}/v1/auth/approle/login")"
  rm -f "${login_payload_file}"
  token="$(echo "${login_json}" | sed -n 's/.*"client_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [[ -n "${token}" ]] || fail "Failed to parse client token for ${role}"

  echo "${token}"
}

assert_contains_policy() {
  local json="$1"
  local policy="$2"
  [[ "${json}" == *"\"${policy}\""* ]] || fail "Missing policy '${policy}'"
}

assert_not_contains_policy() {
  local json="$1"
  local policy="$2"
  [[ "${json}" != *"\"${policy}\""* ]] || fail "Unexpected policy '${policy}'"
}

echo "Validating class policy matrix via AppRole login..."

orchestrator_token="$(spawn_role_token orchestrator)"
orchestrator_lookup="$(lookup_policies_json "${orchestrator_token}")"
assert_contains_policy "${orchestrator_lookup}" "default"
assert_contains_policy "${orchestrator_lookup}" "garrison-base"
assert_contains_policy "${orchestrator_lookup}" "garrison-orchestrator"
ok "orchestrator policy set validated"

rag_token="$(spawn_role_token rag)"
rag_lookup="$(lookup_policies_json "${rag_token}")"
assert_contains_policy "${rag_lookup}" "default"
assert_contains_policy "${rag_lookup}" "garrison-base"
assert_contains_policy "${rag_lookup}" "garrison-rag"
ok "rag policy set validated"

code_token="$(spawn_role_token code)"
code_lookup="$(lookup_policies_json "${code_token}")"
assert_contains_policy "${code_lookup}" "default"
assert_contains_policy "${code_lookup}" "garrison-base"
assert_contains_policy "${code_lookup}" "garrison-code"
ok "code policy set validated"

analyst_token="$(spawn_role_token analyst)"
analyst_lookup="$(lookup_policies_json "${analyst_token}")"
assert_contains_policy "${analyst_lookup}" "default"
assert_contains_policy "${analyst_lookup}" "garrison-base"
assert_not_contains_policy "${analyst_lookup}" "garrison-orchestrator"
assert_not_contains_policy "${analyst_lookup}" "garrison-rag"
assert_not_contains_policy "${analyst_lookup}" "garrison-code"
ok "analyst base-only policy path validated"

echo "Vault class policy matrix checks passed."
