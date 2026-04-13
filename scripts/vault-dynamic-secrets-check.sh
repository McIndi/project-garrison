#!/usr/bin/env bash
set -euo pipefail
umask 077

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"

TMP_FILES=()
cleanup() {
  if [[ ${#TMP_FILES[@]} -gt 0 ]]; then
    rm -f "${TMP_FILES[@]}"
  fi
}
trap cleanup EXIT

fail() {
  echo "[FAIL] $1"
  exit 1
}

ok() {
  echo "[OK] $1"
}

warn() {
  echo "[WARN] $1"
}

api_post() {
  local path="$1"
  local payload="$2"
  curl -fsS -X POST -H "X-Vault-Token: ${VAULT_TOKEN}" -H "Content-Type: application/json" \
    -d "${payload}" "${VAULT_ADDR}${path}"
}

api_put() {
  local path="$1"
  local payload="$2"
  curl -fsS -X PUT -H "X-Vault-Token: ${VAULT_TOKEN}" -H "Content-Type: application/json" \
    -d "${payload}" "${VAULT_ADDR}${path}"
}

extract_json_string() {
  local key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p"
}

extract_json_number() {
  local key="$1"
  sed -n "s/.*\"${key}\"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p"
}

assert_lease_revoked() {
  local lease_id="$1"
  local status
  local lookup_file
  lookup_file="$(mktemp /tmp/garrison-lease-lookup.XXXXXX.json)"
  TMP_FILES+=("${lookup_file}")
  status="$(curl -sS -o "${lookup_file}" -w "%{http_code}" \
    -X PUT -H "X-Vault-Token: ${VAULT_TOKEN}" -H "Content-Type: application/json" \
    -d "{\"lease_id\":\"${lease_id}\"}" "${VAULT_ADDR}/v1/sys/leases/lookup")"

  if [[ "${status}" == "200" ]]; then
    fail "Lease still active after revoke: ${lease_id}"
  fi

  ok "Lease revoked: ${lease_id}"
}

validate_role_lifecycle() {
  local role="$1"
  local mode="${2:-required}"

  local cred_body lease_id username password lease_duration

  if ! cred_body="$(api_get_creds "${role}")"; then
    if [[ "${mode}" == "optional" ]]; then
      warn "Skipping optional role '${role}' (credentials unavailable)"
      return 0
    fi
    fail "Failed to issue dynamic credentials for role: ${role}"
  fi

  lease_id="$(echo "${cred_body}" | extract_json_string lease_id)"
  username="$(echo "${cred_body}" | extract_json_string username)"
  password="$(echo "${cred_body}" | extract_json_string password)"
  lease_duration="$(echo "${cred_body}" | extract_json_number lease_duration)"

  [[ -n "${lease_id}" ]] || fail "Missing lease_id for role: ${role}"
  [[ -n "${username}" ]] || fail "Missing username for role: ${role}"
  [[ -n "${password}" ]] || fail "Missing password for role: ${role}"
  [[ -n "${lease_duration}" && "${lease_duration}" -gt 0 ]] || fail "Invalid lease_duration for role: ${role}"

  ok "Issued credentials for role '${role}' (lease=${lease_id})"

  api_put "/v1/sys/leases/renew" "{\"lease_id\":\"${lease_id}\",\"increment\":\"1h\"}" >/dev/null
  ok "Renewed lease for role '${role}'"

  api_put "/v1/sys/leases/revoke" "{\"lease_id\":\"${lease_id}\"}" >/dev/null
  assert_lease_revoked "${lease_id}"
}

api_get_creds() {
  local role="$1"
  local status
  local body_file

  body_file="$(mktemp "/tmp/garrison-creds-${role}.XXXXXX.json")"
  TMP_FILES+=("${body_file}")
  status="$(curl -sS -o "${body_file}" -w "%{http_code}" -H "X-Vault-Token: ${VAULT_TOKEN}" \
    "${VAULT_ADDR}/v1/database/creds/${role}")"

  if [[ "${status}" != "200" ]]; then
    return 1
  fi

  cat "${body_file}"
}

echo "Validating dynamic secret lifecycle (issue, renew, revoke)..."

validate_role_lifecycle "mongo-readonly" "required"
validate_role_lifecycle "mongo-rag-writer" "required"
validate_role_lifecycle "mongo-code-writer" "required"
validate_role_lifecycle "valkey-readonly" "required"

echo "Vault dynamic secrets lifecycle checks passed."
