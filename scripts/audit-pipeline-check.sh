#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
VAULT_TOKEN="${VAULT_TOKEN:-root}"

if [[ -n "${PYTHON_CMD:-}" ]]; then
  PYTHON_BIN="${PYTHON_CMD}"
elif [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
  PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
else
  PYTHON_BIN="python3"
fi

echo "[1/4] Ensure audit-generating operations run"
curl -fsS -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/sys/health" >/dev/null
curl -fsS -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/auth/token/lookup-self" >/dev/null

BASE_URL="${BASE_URL:-http://127.0.0.1:8080}"
HEADERS=(
  -H "Authorization: Bearer ${VAULT_TOKEN}"
  -H "x-agent-id: agent-root"
  -H "x-agent-class: orchestrator"
  -H "x-human-session-id: human-audit-001"
  -H "x-spawn-depth: 0"
  -H "x-root-orchestrator-id: agent-root"
  -H "Content-Type: application/json"
)
curl -fsS -X POST "${BASE_URL}/tools/fetch" "${HEADERS[@]}" \
  -d '{"url":"http://example.com","method":"GET"}' >/dev/null

echo "[2/4] Wait for Fluent Bit flush"
sleep 6

echo "[3/4] Verify Mongo audit evidence"
"$PYTHON_BIN" - <<'PY'
from pymongo import MongoClient

client = MongoClient("mongodb://root:rootpass@127.0.0.1:27017", serverSelectionTimeoutMS=5000)
db = client["garrison_audit"]

vault_count = db["vault"].count_documents({})
nginx_count = db["nginx"].count_documents({})

if vault_count < 1:
    raise SystemExit("[FAIL] No Vault audit records found in garrison_audit.vault")
if nginx_count < 1:
    raise SystemExit("[FAIL] No Nginx access records found in garrison_audit.nginx")

print(f"[OK] Mongo audit evidence present (vault={vault_count}, nginx={nginx_count})")
PY

echo "[4/4] Audit pipeline check passed"
