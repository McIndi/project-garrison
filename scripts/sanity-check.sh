#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"

echo "[1/5] Health check"
for i in {1..20}; do
  if curl -fsS "${BASE_URL}/health" >/tmp/garrison-health.json 2>/dev/null; then
    cat /tmp/garrison-health.json
    echo
    break
  fi
  if [[ "$i" -eq 20 ]]; then
    echo "Tool-server health check failed after retries"
    exit 1
  fi
  sleep 2
done
echo

HEADERS=(
  -H "Authorization: Bearer demo-token"
  -H "x-agent-id: agent-root"
  -H "x-agent-class: orchestrator"
  -H "x-human-session-id: human-demo-001"
  -H "x-spawn-depth: 0"
  -H "Content-Type: application/json"
)

echo "[2/5] Memory write"
curl -fsS -X POST "${BASE_URL}/tools/memory/agent:agent-root:state" "${HEADERS[@]}" -d '{"value":"ready"}' | cat
echo

echo "[3/5] Memory read"
curl -fsS "${BASE_URL}/tools/memory/agent:agent-root:state" "${HEADERS[@]}" | cat
echo

echo "[4/5] Spawn"
SPAWN_JSON="$(curl -fsS -X POST "${BASE_URL}/tools/spawn" "${HEADERS[@]}" -d '{"agent_class":"rag","task_context":"demo","memory_keys":["shared:memory:demo"]}')"
echo "$SPAWN_JSON"
AGENT_ID="$(echo "$SPAWN_JSON" | sed -n 's/.*"agent_id":"\([^"]*\)".*/\1/p')"

if [[ -z "${AGENT_ID}" ]]; then
  echo "Failed to parse agent_id from spawn response"
  exit 1
fi

echo "[5/5] Delete spawned agent ${AGENT_ID}"
curl -fsS -X DELETE "${BASE_URL}/tools/spawn/${AGENT_ID}" "${HEADERS[@]}" | cat
echo

echo "Sanity check passed"
