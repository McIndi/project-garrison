#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
AUTH_BEARER_TOKEN="${AUTH_BEARER_TOKEN:-}"

if [[ -z "${AUTH_BEARER_TOKEN}" ]]; then
  echo "[FAIL] AUTH_BEARER_TOKEN is required for tool-server fetch checks"
  exit 1
fi

mkdir -p "$ROOT_DIR/logs/nginx"

if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v podman >/dev/null 2>&1 && podman compose version >/dev/null 2>&1; then
  COMPOSE_CMD=(podman compose)
elif command -v podman-compose >/dev/null 2>&1; then
  COMPOSE_CMD=(podman-compose)
else
  echo "Neither docker compose, podman compose, nor podman-compose is available"
  exit 1
fi

echo "[1/3] Verify nginx service is running"
PS_OUTPUT="$("${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" ps)"
echo "$PS_OUTPUT"
if ! echo "$PS_OUTPUT" | grep -E "projectgarrison_nginx_1|nginx" >/dev/null 2>&1; then
  echo "[FAIL] nginx service not found in compose status"
  exit 1
fi

echo "[2/3] Execute proxied fetch through tool-server"
HEADERS=(
  -H "Authorization: Bearer ${AUTH_BEARER_TOKEN}"
  -H "x-agent-id: agent-root"
  -H "x-agent-class: orchestrator"
  -H "x-human-session-id: human-nginx-001"
  -H "x-spawn-depth: 0"
  -H "x-root-orchestrator-id: agent-root"
  -H "Content-Type: application/json"
)

curl -fsS -X POST "${BASE_URL}/tools/fetch" "${HEADERS[@]}" \
  -d '{"url":"http://example.com","method":"GET"}' >/tmp/garrison-nginx-fetch.json
cat /tmp/garrison-nginx-fetch.json
if ! grep -q '"status":200' /tmp/garrison-nginx-fetch.json; then
  echo "[FAIL] proxied fetch did not return HTTP 200"
  exit 1
fi

echo "[3/3] Validate nginx access log evidence"
for attempt in $(seq 1 10); do
  if grep -q "example.com" "$ROOT_DIR/logs/nginx/access.log"; then
    echo "[OK] nginx proxy readiness passed"
    exit 0
  fi
  if [[ "$attempt" -lt 10 ]]; then
    echo "Waiting for nginx access log evidence (${attempt}/10)..."
    sleep 1
  fi
done

echo "[FAIL] nginx access.log does not contain example.com request evidence"
exit 1
