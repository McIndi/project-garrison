#!/usr/bin/env bash
set -euo pipefail

KEYCLOAK_BASE_URL="${KEYCLOAK_BASE_URL:-http://127.0.0.1:8081}"
KEYCLOAK_ADMIN_USER="${KEYCLOAK_ADMIN_USER:-admin}"
KEYCLOAK_ADMIN_PASSWORD="${KEYCLOAK_ADMIN_PASSWORD:-admin}"
KEYCLOAK_REALM="${KEYCLOAK_REALM:-garrison}"
KEYCLOAK_OPENWEBUI_CLIENT_ID="${KEYCLOAK_OPENWEBUI_CLIENT_ID:-open-webui}"
KEYCLOAK_ORCHESTRATOR_ROLE="${KEYCLOAK_ORCHESTRATOR_ROLE:-garrison-orchestrator}"
KEYCLOAK_ORCHESTRATOR_GROUP="${KEYCLOAK_ORCHESTRATOR_GROUP:-garrison-orchestrators}"

PYTHON_BIN="${PYTHON_BIN:-python3}"

json_field() {
  local expr="$1"
  "$PYTHON_BIN" -c "import json,sys; data=json.load(sys.stdin); print(${expr})"
}

TOKEN="$(curl -fsS -X POST \
  -H "Content-Type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=admin-cli" \
  -d "username=${KEYCLOAK_ADMIN_USER}" \
  -d "password=${KEYCLOAK_ADMIN_PASSWORD}" \
  "${KEYCLOAK_BASE_URL}/realms/master/protocol/openid-connect/token" | json_field "data.get('access_token','')")"

if [[ -z "$TOKEN" ]]; then
  echo "[FAIL] Could not obtain Keycloak admin token"
  exit 1
fi

curl -fsS -H "Authorization: Bearer ${TOKEN}" "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}" >/dev/null
echo "[OK] Keycloak realm exists: ${KEYCLOAK_REALM}"

CLIENTS="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/clients?clientId=${KEYCLOAK_OPENWEBUI_CLIENT_ID}")"
CLIENT_ID="$(printf '%s' "$CLIENTS" | json_field "(data[0]['id'] if data else '')")"
if [[ -z "$CLIENT_ID" ]]; then
  echo "[FAIL] Keycloak client missing: ${KEYCLOAK_OPENWEBUI_CLIENT_ID}"
  exit 1
fi
echo "[OK] Keycloak client exists: ${KEYCLOAK_OPENWEBUI_CLIENT_ID}"

curl -fsS -H "Authorization: Bearer ${TOKEN}" "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/roles/${KEYCLOAK_ORCHESTRATOR_ROLE}" >/dev/null
echo "[OK] Keycloak role exists: ${KEYCLOAK_ORCHESTRATOR_ROLE}"

GROUPS="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/groups?search=${KEYCLOAK_ORCHESTRATOR_GROUP}")"
GROUP_ID="$(printf '%s' "$GROUPS" | "$PYTHON_BIN" -c "import json,sys; data=json.load(sys.stdin);\nname='${KEYCLOAK_ORCHESTRATOR_GROUP}';\nprint(next((g['id'] for g in data if g.get('name')==name),''))")"
if [[ -z "$GROUP_ID" ]]; then
  echo "[FAIL] Keycloak group missing: ${KEYCLOAK_ORCHESTRATOR_GROUP}"
  exit 1
fi
echo "[OK] Keycloak group exists: ${KEYCLOAK_ORCHESTRATOR_GROUP}"

GROUP_ROLES="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" "${KEYCLOAK_BASE_URL}/admin/realms/${KEYCLOAK_REALM}/groups/${GROUP_ID}/role-mappings/realm")"
HAS_ROLE="$(printf '%s' "$GROUP_ROLES" | "$PYTHON_BIN" -c "import json,sys; data=json.load(sys.stdin); role='${KEYCLOAK_ORCHESTRATOR_ROLE}'; print('true' if any(r.get('name')==role for r in data) else 'false')")"
if [[ "$HAS_ROLE" != "true" ]]; then
  echo "[FAIL] Keycloak group ${KEYCLOAK_ORCHESTRATOR_GROUP} is not mapped to role ${KEYCLOAK_ORCHESTRATOR_ROLE}"
  exit 1
fi
echo "[OK] Keycloak role mapping exists: ${KEYCLOAK_ORCHESTRATOR_GROUP} -> ${KEYCLOAK_ORCHESTRATOR_ROLE}"

echo "Keycloak readiness checks passed"