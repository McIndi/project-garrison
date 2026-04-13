#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_BASE_URL="${KEYCLOAK_BASE_URL:-http://127.0.0.1:8081}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-garrison}"
KEYCLOAK_OPENWEBUI_CLIENT_ID="${KEYCLOAK_OPENWEBUI_CLIENT_ID:-open-webui}"
KEYCLOAK_OPENWEBUI_CLIENT_SECRET="${KEYCLOAK_OPENWEBUI_CLIENT_SECRET:-garrison-openwebui-secret}"
KEYCLOAK_ORCHESTRATOR_ROLE="${KEYCLOAK_ORCHESTRATOR_ROLE:-garrison-orchestrator}"
KEYCLOAK_ORCHESTRATOR_GROUP="${KEYCLOAK_ORCHESTRATOR_GROUP:-garrison-orchestrators}"

PYTHON_BIN="${PYTHON_BIN:-python3}"

json_field() {
  local expr="$1"
  "$PYTHON_BIN" -c "import json,sys; data=json.load(sys.stdin); print(${expr})"
}

api_token() {
  curl -fsS -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=password" \
    -d "client_id=admin-cli" \
    -d "username=${KEYCLOAK_ADMIN_USER}" \
    -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
    "${KEYCLOAK_BASE_URL}/realms/master/protocol/openid-connect/token" \
    | json_field "data.get('access_token','')"
}

api_get_status() {
  local token="$1"
  local path="$2"
  local out_file
  out_file="$(mktemp)"
  local status
  status="$(curl -sS -o "$out_file" -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    "${KEYCLOAK_BASE_URL}${path}")"
  cat "$out_file"
  rm -f "$out_file"
  printf '\n%s' "$status"
}

api_post() {
  local token="$1"
  local path="$2"
  local payload="$3"
  curl -fsS -X POST \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${KEYCLOAK_BASE_URL}${path}" >/dev/null
}

api_put() {
  local token="$1"
  local path="$2"
  local payload="$3"
  curl -fsS -X PUT \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -d "$payload" \
    "${KEYCLOAK_BASE_URL}${path}" >/dev/null
}

wait_for_keycloak() {
  for _ in {1..60}; do
    if curl -fsS "${KEYCLOAK_BASE_URL}/realms/master/.well-known/openid-configuration" >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  echo "Keycloak did not become ready in time" >&2
  return 1
}

wait_for_keycloak
TOKEN="$(api_token)"
if [[ -z "$TOKEN" ]]; then
  echo "Failed to get Keycloak admin token" >&2
  exit 1
fi

REALM_CHECK_RAW="$(api_get_status "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}")"
REALM_STATUS="$(printf '%s' "$REALM_CHECK_RAW" | tail -n1)"
if [[ "$REALM_STATUS" == "404" ]]; then
  api_post "$TOKEN" "/admin/realms" "$(cat <<JSON
{
  \"realm\": \"${KEYCLOAK_REALM}\",
  \"enabled\": true
}
JSON
)"
elif [[ "$REALM_STATUS" != "200" ]]; then
  echo "Unexpected Keycloak realm lookup status: ${REALM_STATUS}" >&2
  exit 1
fi

CLIENT_LIST="$(curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_OPENWEBUI_CLIENT_ID}")"
CLIENT_ID="$(printf '%s' "$CLIENT_LIST" | json_field "(data[0]['id'] if data else '')")"
if [[ -z "$CLIENT_ID" ]]; then
  api_post "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/clients" "$(cat <<JSON
{
  \"clientId\": \"${KEYCLOAK_OPENWEBUI_CLIENT_ID}\",
  \"name\": \"Open WebUI\",
  \"enabled\": true,
  \"protocol\": \"openid-connect\",
  \"publicClient\": false,
  \"secret\": \"${KEYCLOAK_OPENWEBUI_CLIENT_SECRET}\",
  \"redirectUris\": [\"http://127.0.0.1:3000/*\", \"http://open-webui:8080/*\"],
  \"webOrigins\": [\"http://127.0.0.1:3000\", \"http://open-webui:8080\"],
  \"standardFlowEnabled\": true,
  \"directAccessGrantsEnabled\": false
}
JSON
)"

  CLIENT_LIST="$(curl -fsS \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_OPENWEBUI_CLIENT_ID}")"
  CLIENT_ID="$(printf '%s' "$CLIENT_LIST" | json_field "(data[0]['id'] if data else '')")"
fi

ROLE_GET_RAW="$(api_get_status "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/roles/${KEYCLOAK_ORCHESTRATOR_ROLE}")"
ROLE_GET_STATUS="$(printf '%s' "$ROLE_GET_RAW" | tail -n1)"
if [[ "$ROLE_GET_STATUS" == "404" ]]; then
  api_post "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/roles" "$(cat <<JSON
{
  \"name\": \"${KEYCLOAK_ORCHESTRATOR_ROLE}\",
  \"description\": \"Can initiate orchestration requests\"
}
JSON
)"
elif [[ "$ROLE_GET_STATUS" != "200" ]]; then
  echo "Unexpected Keycloak role lookup status: ${ROLE_GET_STATUS}" >&2
  exit 1
fi

GROUP_LIST="$(curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/groups?search=${KEYCLOAK_ORCHESTRATOR_GROUP}")"
GROUP_ID="$(printf '%s' "$GROUP_LIST" | "$PYTHON_BIN" -c "import json,sys; data=json.load(sys.stdin);\nname='${KEYCLOAK_ORCHESTRATOR_GROUP}';\nprint(next((g['id'] for g in data if g.get('name')==name),''))")"
if [[ -z "$GROUP_ID" ]]; then
  api_post "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/groups" "$(cat <<JSON
{
  \"name\": \"${KEYCLOAK_ORCHESTRATOR_GROUP}\"
}
JSON
)"
  GROUP_LIST="$(curl -fsS \
    -H "Authorization: Bearer ${TOKEN}" \
    "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/groups?search=${KEYCLOAK_ORCHESTRATOR_GROUP}")"
  GROUP_ID="$(printf '%s' "$GROUP_LIST" | "$PYTHON_BIN" -c "import json,sys; data=json.load(sys.stdin);\nname='${KEYCLOAK_ORCHESTRATOR_GROUP}';\nprint(next((g['id'] for g in data if g.get('name')==name),''))")"
fi

ROLE_DOC="$(curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/roles/${KEYCLOAK_ORCHESTRATOR_ROLE}")"
ROLE_ID="$(printf '%s' "$ROLE_DOC" | json_field "data.get('id','')")"

GROUP_ROLES="$(curl -fsS \
  -H "Authorization: Bearer ${TOKEN}" \
  "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/groups/${GROUP_ID}/role-mappings/realm")"
HAS_ROLE="$(printf '%s' "$GROUP_ROLES" | "$PYTHON_BIN" -c "import json,sys; data=json.load(sys.stdin); role='${KEYCLOAK_ORCHESTRATOR_ROLE}'; print('true' if any(r.get('name')==role for r in data) else 'false')")"
if [[ "$HAS_ROLE" != "true" ]]; then
  api_post "$TOKEN" "/admin/realms/${KEYCLOAK_REALM}/groups/${GROUP_ID}/role-mappings/realm" "$(cat <<JSON
[
  {
    \"id\": \"${ROLE_ID}\",
    \"name\": \"${KEYCLOAK_ORCHESTRATOR_ROLE}\"
  }
]
JSON
)"
fi

echo "Keycloak bootstrap configured realm=${KEYCLOAK_REALM}, client=${KEYCLOAK_OPENWEBUI_CLIENT_ID}, group=${KEYCLOAK_ORCHESTRATOR_GROUP}, role=${KEYCLOAK_ORCHESTRATOR_ROLE}"