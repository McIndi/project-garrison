#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:8080}"
AUTH_BEARER_TOKEN="${AUTH_BEARER_TOKEN:-root}"

echo "[1/12] Health check"
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
  -H "Authorization: Bearer ${AUTH_BEARER_TOKEN}"
  -H "x-agent-id: agent-root"
  -H "x-agent-class: orchestrator"
  -H "x-human-session-id: human-demo-001"
  -H "x-spawn-depth: 0"
  -H "x-root-orchestrator-id: agent-root"
  -H "Content-Type: application/json"
)

echo "[2/12] Memory write"
curl -fsS -X POST "${BASE_URL}/tools/memory/agent:agent-root:state" "${HEADERS[@]}" -d '{"value":"ready"}' | cat
echo

echo "[3/12] Memory read"
curl -fsS "${BASE_URL}/tools/memory/agent:agent-root:state" "${HEADERS[@]}" | cat
echo

echo "[4/12] Scratch write/read"
curl -fsS -X POST "${BASE_URL}/tools/scratch/demo-note" "${HEADERS[@]}" -d '{"value":"draft","ttl_seconds":120}' | cat
echo
curl -fsS "${BASE_URL}/tools/scratch/demo-note" "${HEADERS[@]}" | cat
echo

echo "[5/12] Registry read"
curl -fsS "${BASE_URL}/tools/registry" "${HEADERS[@]}" | cat
echo

echo "[6/12] Summarize"
curl -fsS -X POST "${BASE_URL}/tools/summarize" "${HEADERS[@]}" -d '{"content":"Garrison enforces policy and audit controls for agents.","max_tokens":64,"format":"bullets"}' | cat
echo

echo "[7/12] Encrypt/Decrypt"
ENC_JSON="$(curl -fsS -X POST "${BASE_URL}/tools/encrypt" "${HEADERS[@]}" -d '{"plaintext":"aGVsbG8=","key":"agent-payload"}')"
echo "$ENC_JSON"
CIPHERTEXT="$(echo "$ENC_JSON" | sed -n 's/.*"ciphertext":"\([^"]*\)".*/\1/p')"
if [[ -z "${CIPHERTEXT}" ]]; then
  echo "Failed to parse ciphertext"
  exit 1
fi
curl -fsS -X POST "${BASE_URL}/tools/decrypt" "${HEADERS[@]}" -d "{\"ciphertext\":\"${CIPHERTEXT}\",\"key\":\"agent-payload\"}" | cat
echo

echo "[8/12] Search"
curl -fsS -X POST "${BASE_URL}/tools/search" "${HEADERS[@]}" -d '{"query":"garrison","corpus":"shared_artifacts.objects","top_k":3}' | cat
echo

echo "[9/12] Spawn"
SPAWN_JSON="$(curl -fsS -X POST "${BASE_URL}/tools/spawn" "${HEADERS[@]}" -d '{"agent_class":"rag","task_context":"demo","memory_keys":["shared:memory:demo"]}')"
echo "$SPAWN_JSON"
AGENT_ID="$(echo "$SPAWN_JSON" | sed -n 's/.*"agent_id":"\([^"]*\)".*/\1/p')"

if [[ -z "${AGENT_ID}" ]]; then
  echo "Failed to parse agent_id from spawn response"
  exit 1
fi

echo "[10/12] Delete spawned agent ${AGENT_ID}"
curl -fsS -X DELETE "${BASE_URL}/tools/spawn/${AGENT_ID}" "${HEADERS[@]}" | cat
echo

echo "[11/12] Orchestrate bridge"
ORCH_JSON="$(curl -fsS -X POST "${BASE_URL}/orchestrate" "${HEADERS[@]}" -d '{"request_text":"delegate summary task","human_session_id":"human-demo-001","preferred_agent_class":"rag"}')"
echo "$ORCH_JSON"
ORCH_AGENT_ID="$(echo "$ORCH_JSON" | sed -n 's/.*"spawned_agent_id":"\([^"]*\)".*/\1/p')"
if [[ -z "${ORCH_AGENT_ID}" ]]; then
  echo "Failed to parse spawned_agent_id from orchestrate response"
  exit 1
fi

echo "[12/12] Delete orchestrated agent ${ORCH_AGENT_ID}"
curl -fsS -X DELETE "${BASE_URL}/tools/spawn/${ORCH_AGENT_ID}" "${HEADERS[@]}" | cat
echo

echo "Sanity check passed"
