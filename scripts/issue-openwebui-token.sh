#!/usr/bin/env bash
set -euo pipefail

VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"
TOKEN_TTL="${OPENWEBUI_TOKEN_TTL:-1h}"
AGENT_ID="${GARRISON_ORCHESTRATE_AGENT_ID:-agent-root}"
AGENT_CLASS="${GARRISON_ORCHESTRATE_AGENT_CLASS:-orchestrator}"

PAYLOAD="$(cat <<JSON
{
  "policies": ["default", "garrison-base", "garrison-orchestrator"],
  "ttl": "${TOKEN_TTL}",
  "renewable": true,
  "meta": {
    "agent_id": "${AGENT_ID}",
    "agent_class": "${AGENT_CLASS}",
    "issued_for": "open-webui-orchestrate"
  }
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
  echo "Failed to issue Open WebUI orchestrate token" >&2
  echo "Vault response: ${RESP}" >&2
  exit 1
fi

printf '%s\n' "${TOKEN}"
