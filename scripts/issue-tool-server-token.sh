#!/usr/bin/env bash
# Issue a scoped Vault token for the tool-server service identity.
# This token is used instead of the Vault root token and is restricted to
# exactly the operations tool-server performs at runtime (see garrison-tool-server policy).
# Called by bootstrap.sh during stack initialisation.
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
TOKEN_TTL="${TOOL_SERVER_TOKEN_TTL:-24h}"

PAYLOAD="$(cat <<JSON
{
  "policies": ["default", "garrison-tool-server"],
  "ttl": "${TOKEN_TTL}",
  "renewable": true,
  "display_name": "tool-server-service"
}
JSON
)"

RESP="$(curl -fsS -X POST \
  -H "X-Vault-Token: ${VAULT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d "${PAYLOAD}" \
  "${VAULT_ADDR}/v1/auth/token/create")"

TOKEN="$(printf '%s' "${RESP}" | sed -n 's/.*"client_token":"\([^"]*\)".*/\1/p')"
if [[ -z "${TOKEN}" ]]; then
  echo "Failed to issue tool-server service token" >&2
  echo "Vault response: ${RESP}" >&2
  exit 1
fi

printf '%s\n' "${TOKEN}"
