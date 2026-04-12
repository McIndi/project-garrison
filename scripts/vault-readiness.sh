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

api_get() {
  local path="$1"
  curl -fsS -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}${path}"
}

audit_json="$(api_get /v1/sys/audit)"
auth_json="$(api_get /v1/sys/auth)"
mounts_json="$(api_get /v1/sys/mounts)"

[[ "${audit_json}" == *'"file/"'* ]] || fail "Vault file audit device is missing"
ok "Vault file audit device enabled"

[[ "${auth_json}" == *'"approle/"'* ]] || fail "Vault AppRole auth mount is missing"
ok "Vault AppRole auth mount enabled"

[[ "${mounts_json}" == *'"transit/"'* ]] || fail "Vault transit engine is missing"
ok "Vault transit engine enabled"

for role in orchestrator code rag analyst; do
  role_json="$(api_get "/v1/auth/approle/role/${role}/role-id")"
  [[ "${role_json}" == *'"role_id"'* ]] || fail "Missing AppRole role: ${role}"
  ok "AppRole role exists: ${role}"
done

for key in agent-payload shared-memory artifact-signing; do
  key_json="$(api_get "/v1/transit/keys/${key}")"
  [[ "${key_json}" == *'"name":"'"${key}"'"'* ]] || fail "Missing transit key: ${key}"
  ok "Transit key exists: ${key}"
done

echo "Vault readiness checks passed."
