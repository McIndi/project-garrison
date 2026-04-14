#!/usr/bin/env bash
set -euo pipefail

GARRISON_TERRAFORM="${GARRISON_TERRAFORM:-false}"

KEYCLOAK_BASE_URL="${KEYCLOAK_BASE_URL:-http://127.0.0.1:8081}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-garrison}"
KEYCLOAK_OPENWEBUI_CLIENT_ID="${KEYCLOAK_OPENWEBUI_CLIENT_ID:-open-webui}"
KEYCLOAK_OPENWEBUI_CLIENT_SECRET="${KEYCLOAK_OPENWEBUI_CLIENT_SECRET:-}"
KEYCLOAK_ORCHESTRATOR_ROLE="${KEYCLOAK_ORCHESTRATOR_ROLE:-garrison-orchestrator}"
KEYCLOAK_ORCHESTRATOR_GROUP="${KEYCLOAK_ORCHESTRATOR_GROUP:-garrison-orchestrators}"

if [[ "${GARRISON_TERRAFORM}" == "true" ]]; then
  echo "[Keycloak] Running in Terraform workflow mode (Vault baseline is managed by Terraform/OpenTofu)."
fi

if [[ -z "${KEYCLOAK_OPENWEBUI_CLIENT_SECRET}" ]]; then
  KEYCLOAK_OPENWEBUI_CLIENT_SECRET="$(head -c 32 /dev/urandom | base64 | tr -d '=+/\n' | cut -c1-32)"
  echo "[Keycloak] Generated runtime client secret for ${KEYCLOAK_OPENWEBUI_CLIENT_ID}"
fi

PYTHON_BIN="${PYTHON_BIN:-python3}"
KEYCLOAK_READY_RETRIES="${KEYCLOAK_READY_RETRIES:-60}"
KEYCLOAK_READY_DELAY_SECONDS="${KEYCLOAK_READY_DELAY_SECONDS:-2}"

json_field() {
  local expr="$1"
  "$PYTHON_BIN" -c "import json,sys; data=json.load(sys.stdin); print(${expr})"
}

extract_json_field() {
  local expr="$1"
  local input="$2"
  printf '%s' "$input" | "$PYTHON_BIN" -c "import json,sys; data=json.load(sys.stdin); print(${expr})"
}

kc_request() {
  local method="$1"
  local path="$2"
  local token="$3"
  local payload="${4:-}"
  local body_file
  body_file="$(mktemp)"
  local status
  local curl_args=(
    -sS
    -o "$body_file"
    -w "%{http_code}"
    -X "$method"
  )

  if [[ -n "$token" ]]; then
    curl_args+=( -H "Authorization: Bearer ${token}" )
  fi

  if [[ -n "$payload" ]]; then
    curl_args+=( -H "Content-Type: application/json" -d "$payload" )
  fi

  status="$(curl "${curl_args[@]}" "${KEYCLOAK_BASE_URL}${path}")" || status="000"

  printf '%s\n%s' "$(cat "$body_file")" "$status"
  rm -f "$body_file"
}

kc_expect_success() {
  local method="$1"
  local path="$2"
  local token="$3"
  local payload="${4:-}"
  local response
  response="$(kc_request "$method" "$path" "$token" "$payload")"
  local body
  body="$(printf '%s' "$response" | sed '$d')"
  local status
  status="$(printf '%s' "$response" | tail -n1)"

  if [[ "$status" -lt 200 || "$status" -ge 300 ]]; then
    echo "[Keycloak] ${method} ${path} failed: HTTP ${status}" >&2
    if [[ -n "$body" ]]; then
      echo "[Keycloak] Response body:" >&2
      printf '%s\n' "$body" >&2
    fi
    return 1
  fi

  printf '%s' "$body"
}

kc_get_json() {
  local token="$1"
  local path="$2"
  kc_expect_success GET "$path" "$token"
}

kc_get_status() {
  local path="$1"
  local token="$2"
  local response
  response="$(kc_request GET "$path" "$token")"
  printf '%s' "$response" | tail -n1
}

kc_post() {
  local token="$1"
  local path="$2"
  local payload="$3"
  kc_expect_success POST "$path" "$token" "$payload" >/dev/null
}

find_named_group_id() {
  local groups_json="$1"
  extract_json_field "next((g['id'] for g in data if g.get('name')=='${KEYCLOAK_ORCHESTRATOR_GROUP}'),'')" "$groups_json"
}

wait_for_keycloak() {
  local attempt
  for attempt in $(seq 1 "$KEYCLOAK_READY_RETRIES"); do
    if curl -fsS "${KEYCLOAK_BASE_URL}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
      local token_response
      token_response="$(curl -sS -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=password" \
        -d "client_id=admin-cli" \
        -d "username=${KEYCLOAK_ADMIN_USER}" \
        -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
        "${KEYCLOAK_BASE_URL}/realms/master/protocol/openid-connect/token")" || token_response=""
      local token
      token="$(extract_json_field "data.get('access_token','')" "$token_response" 2>/dev/null || true)"
      if [[ -n "$token" ]]; then
        printf '%s' "$token"
        return 0
      fi
    fi
    echo "Waiting for Keycloak admin API readiness (${attempt}/${KEYCLOAK_READY_RETRIES})..." >&2
    sleep "$KEYCLOAK_READY_DELAY_SECONDS"
  done
  echo "Keycloak did not become ready in time" >&2
  return 1
}

TOKEN="$(wait_for_keycloak)"
if [[ -z "$TOKEN" ]]; then
  echo "Failed to get Keycloak admin token" >&2
  exit 1
fi

REALM_STATUS="$(kc_get_status "/admin/realms/${KEYCLOAK_REALM}" "$TOKEN")"
if [[ "$REALM_STATUS" == "404" ]]; then
  kc_post "$TOKEN" "/admin/realms" "$(cat <<JSON
{
  "realm": "${KEYCLOAK_REALM}",
  "enabled": true
}
JSON
)"
elif [[ "$REALM_STATUS" != "200" ]]; then
  echo "Unexpected Keycloak realm lookup status: ${REALM_STATUS}" >&2
  exit 1
fi

CLIENT_LIST="$(kc_get_json "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_OPENWEBUI_CLIENT_ID}")"
CLIENT_ID="$(extract_json_field "(data[0]['id'] if data else '')" "$CLIENT_LIST")"
if [[ -z "$CLIENT_ID" ]]; then
  kc_post "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/clients" "$(cat <<JSON
{
  "clientId": "${KEYCLOAK_OPENWEBUI_CLIENT_ID}",
  "name": "Open WebUI",
  "enabled": true,
  "protocol": "openid-connect",
  "publicClient": false,
  "secret": "${KEYCLOAK_OPENWEBUI_CLIENT_SECRET}",
  "redirectUris": ["http://127.0.0.1:3000/*", "http://open-webui:8080/*"],
  "webOrigins": ["http://127.0.0.1:3000", "http://open-webui:8080"],
  "standardFlowEnabled": true,
  "directAccessGrantsEnabled": false
}
JSON
)"

  CLIENT_LIST="$(kc_get_json "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_OPENWEBUI_CLIENT_ID}")"
  CLIENT_ID="$(extract_json_field "(data[0]['id'] if data else '')" "$CLIENT_LIST")"
  if [[ -z "$CLIENT_ID" ]]; then
    echo "Failed to resolve Keycloak client after creation: ${KEYCLOAK_OPENWEBUI_CLIENT_ID}" >&2
    exit 1
  fi
fi

ROLE_GET_STATUS="$(kc_get_status "/admin/realms/${KEYCLOAK_REALM}/roles/${KEYCLOAK_ORCHESTRATOR_ROLE}" "$TOKEN")"
if [[ "$ROLE_GET_STATUS" == "404" ]]; then
  kc_post "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/roles" "$(cat <<JSON
{
  "name": "${KEYCLOAK_ORCHESTRATOR_ROLE}",
  "description": "Can initiate orchestration requests"
}
JSON
)"
elif [[ "$ROLE_GET_STATUS" != "200" ]]; then
  echo "Unexpected Keycloak role lookup status: ${ROLE_GET_STATUS}" >&2
  exit 1
fi

GROUP_LIST="$(kc_get_json "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/groups?search=${KEYCLOAK_ORCHESTRATOR_GROUP}")"
GROUP_ID="$(find_named_group_id "$GROUP_LIST")"
if [[ -z "$GROUP_ID" ]]; then
  kc_post "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/groups" "$(cat <<JSON
{
  "name": "${KEYCLOAK_ORCHESTRATOR_GROUP}"
}
JSON
)"
  GROUP_LIST="$(kc_get_json "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/groups?search=${KEYCLOAK_ORCHESTRATOR_GROUP}")"
  GROUP_ID="$(find_named_group_id "$GROUP_LIST")"
  if [[ -z "$GROUP_ID" ]]; then
    echo "Failed to resolve Keycloak group after creation: ${KEYCLOAK_ORCHESTRATOR_GROUP}" >&2
    exit 1
  fi
fi

ROLE_DOC="$(kc_get_json "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/roles/${KEYCLOAK_ORCHESTRATOR_ROLE}")"
ROLE_ID="$(extract_json_field "data.get('id','')" "$ROLE_DOC")"
if [[ -z "$ROLE_ID" ]]; then
  echo "Failed to resolve Keycloak role id for ${KEYCLOAK_ORCHESTRATOR_ROLE}" >&2
  exit 1
fi

GROUP_ROLES="$(kc_get_json "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/groups/${GROUP_ID}/role-mappings/realm")"
HAS_ROLE="$(extract_json_field "'true' if any(r.get('name')=='${KEYCLOAK_ORCHESTRATOR_ROLE}' for r in data) else 'false'" "$GROUP_ROLES")"
if [[ "$HAS_ROLE" != "true" ]]; then
  kc_post "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/groups/${GROUP_ID}/role-mappings/realm" "$(cat <<JSON
[
  {
    "id": "${ROLE_ID}",
    "name": "${KEYCLOAK_ORCHESTRATOR_ROLE}",
    "clientRole": false,
    "composite": false,
    "containerId": "${KEYCLOAK_REALM}"
  }
]
JSON
)"
fi

echo "Keycloak bootstrap configured realm=${KEYCLOAK_REALM}, client=${KEYCLOAK_OPENWEBUI_CLIENT_ID}, group=${KEYCLOAK_ORCHESTRATOR_GROUP}, role=${KEYCLOAK_ORCHESTRATOR_ROLE}"