#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GARRISON_TERRAFORM="${GARRISON_TERRAFORM:-false}"
VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
GARRISON_VAULT_INIT_FILE="${GARRISON_VAULT_INIT_FILE:-$ROOT_DIR/logs/vault/init.json}"

cd "$ROOT_DIR"

if grep -Eiq 'WEBUI_AUTH:\s*"?False"?' "$ROOT_DIR/compose.yaml"; then
	if [[ "${ALLOW_INSECURE_WEBUI_AUTH:-false}" != "true" ]]; then
		echo "Refusing to bootstrap: WEBUI_AUTH is disabled in compose.yaml"
		echo "Set ALLOW_INSECURE_WEBUI_AUTH=true to bypass this check for local troubleshooting."
		exit 1
	fi
	echo "[WARN] Proceeding with insecure Open WebUI auth because ALLOW_INSECURE_WEBUI_AUTH=true"
fi

if command -v docker >/dev/null 2>&1; then
	COMPOSE_CMD=(docker compose)
elif command -v podman >/dev/null 2>&1; then
	COMPOSE_CMD=(podman compose)
else
	echo "Neither docker nor podman is available"
	exit 1
fi

if [[ -z "${TOOL_SERVER_AUDIT_INGEST_TOKEN:-}" ]]; then
	echo "Issuing runtime audit ingest token..."
	TOOL_SERVER_AUDIT_INGEST_TOKEN="$("$ROOT_DIR/scripts/issue-audit-ingest-token.sh")"
	if [[ -z "${TOOL_SERVER_AUDIT_INGEST_TOKEN}" ]]; then
		echo "Failed to generate audit ingest token"
		exit 1
	fi
	export TOOL_SERVER_AUDIT_INGEST_TOKEN
fi

echo "Starting core stack..."
TOOL_SERVER_AUDIT_INGEST_TOKEN="${TOOL_SERVER_AUDIT_INGEST_TOKEN}" \
	"${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" up -d --build \
	valkey mongo vault beeai-runtime nginx fluent-bit otel-collector keycloak

echo "Preparing Vault audit log path permissions..."
"${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" exec -T -u root vault sh -c 'mkdir -p /vault/logs && touch /vault/logs/audit.log && chown vault:vault /vault/logs /vault/logs/audit.log && chmod 0700 /vault/logs && chmod 0600 /vault/logs/audit.log' || true

echo "Waiting for Vault API readiness..."
for attempt in $(seq 1 30); do
	vault_http_code="$(curl -sS -o /dev/null --max-time 2 -w '%{http_code}' "${VAULT_ADDR}/v1/sys/health" || true)"
	if [[ "${vault_http_code}" != "000" ]]; then
		break
	fi
	if [[ "$attempt" -eq 30 ]]; then
		echo "Vault did not become ready in time"
		exit 1
	fi
	sleep 2
done

if ! mkdir -p "$(dirname "${GARRISON_VAULT_INIT_FILE}")" 2>/dev/null; then
	fallback_init_file="${TMPDIR:-/tmp}/garrison-vault-init.json"
	echo "[WARN] Cannot write to ${GARRISON_VAULT_INIT_FILE}; using ${fallback_init_file} instead."
	GARRISON_VAULT_INIT_FILE="${fallback_init_file}"
	mkdir -p "$(dirname "${GARRISON_VAULT_INIT_FILE}")"
fi

vault_init_status="$(curl -fsS --max-time 3 "${VAULT_ADDR}/v1/sys/init" || true)"
if [[ "${vault_init_status}" == *'"initialized":false'* ]]; then
	echo "Initializing Vault (single unseal key for local/CI automation)..."
	"${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" exec -T vault sh -c \
		'vault operator init -key-shares=1 -key-threshold=1 -format=json' >"${GARRISON_VAULT_INIT_FILE}"
	chmod 600 "${GARRISON_VAULT_INIT_FILE}"
fi

if [[ ! -s "${GARRISON_VAULT_INIT_FILE}" ]]; then
	echo "Vault init file not found at ${GARRISON_VAULT_INIT_FILE}; cannot continue." >&2
	exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
	echo "python3 is required to parse ${GARRISON_VAULT_INIT_FILE}" >&2
	exit 1
fi

UNSEAL_KEY="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print((d.get("unseal_keys_b64") or [""])[0])' "${GARRISON_VAULT_INIT_FILE}")"
VAULT_TOKEN="$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get("root_token", ""))' "${GARRISON_VAULT_INIT_FILE}")"

if [[ -z "${UNSEAL_KEY}" || -z "${VAULT_TOKEN}" ]]; then
	echo "Failed to parse unseal key or root token from ${GARRISON_VAULT_INIT_FILE}" >&2
	exit 1
fi

vault_seal_status="$(curl -fsS --max-time 3 "${VAULT_ADDR}/v1/sys/seal-status" || true)"
if [[ "${vault_seal_status}" == *'"sealed":true'* ]]; then
	echo "Unsealing Vault..."
	curl -fsS -X POST -H "Content-Type: application/json" \
		-d "{\"key\":\"${UNSEAL_KEY}\"}" \
		"${VAULT_ADDR}/v1/sys/unseal" >/dev/null
fi

export VAULT_TOKEN

if [[ "${GARRISON_TERRAFORM}" == "true" ]]; then
	echo "Configuring Vault baseline for dynamic/auditable secrets via Terraform/OpenTofu..."
else
	echo "Configuring Vault baseline for dynamic/auditable secrets via script bootstrap..."
fi
"$ROOT_DIR/scripts/vault-bootstrap.sh"

if [[ -z "${KEYCLOAK_OPENWEBUI_CLIENT_SECRET:-}" ]]; then
	KEYCLOAK_OPENWEBUI_CLIENT_SECRET="$(head -c 32 /dev/urandom | base64 | tr -d '=+/\n' | cut -c1-32)"
	export KEYCLOAK_OPENWEBUI_CLIENT_SECRET
	echo "Generated runtime Keycloak Open WebUI client secret"
fi

echo "Issuing scoped tool-server runtime token from Vault..."
TOOL_SERVER_VAULT_TOKEN_RUNTIME="$($ROOT_DIR/scripts/issue-tool-server-token.sh)"
if [[ -z "${TOOL_SERVER_VAULT_TOKEN_RUNTIME}" ]]; then
	echo "Failed to obtain tool-server runtime token"
	exit 1
fi

echo "Configuring Keycloak realm/client/role/group baseline..."
"$ROOT_DIR/scripts/keycloak-bootstrap.sh"

echo "Running Keycloak readiness checks..."
"$ROOT_DIR/scripts/keycloak-readiness.sh"

echo "Issuing scoped Open WebUI orchestrate token from Vault..."
OPENWEBUI_ORCH_TOKEN="$("$ROOT_DIR/scripts/issue-openwebui-token.sh")"
if [[ -z "${OPENWEBUI_ORCH_TOKEN}" ]]; then
	echo "Failed to obtain Open WebUI orchestration token"
	exit 1
fi

echo "Starting tool-server with runtime-scoped Vault token..."
TOOL_SERVER_AUDIT_INGEST_TOKEN="${TOOL_SERVER_AUDIT_INGEST_TOKEN}" \
	TOOL_SERVER_VAULT_TOKEN="${TOOL_SERVER_VAULT_TOKEN_RUNTIME}" \
	"${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" up -d tool-server

echo "Starting Open WebUI with runtime-scoped orchestrate token..."
TOOL_SERVER_AUDIT_INGEST_TOKEN="${TOOL_SERVER_AUDIT_INGEST_TOKEN}" \
	TOOL_SERVER_VAULT_TOKEN="${TOOL_SERVER_VAULT_TOKEN_RUNTIME}" \
	GARRISON_ORCHESTRATE_BEARER_TOKEN="${OPENWEBUI_ORCH_TOKEN}" \
	"${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" up -d open-webui

export AUTH_BEARER_TOKEN="${OPENWEBUI_ORCH_TOKEN}"

echo "Running Vault readiness checks..."
"$ROOT_DIR/scripts/vault-readiness.sh"

echo "Running Vault policy matrix checks..."
"$ROOT_DIR/scripts/vault-policy-check.sh"

echo "Running Vault dynamic secrets lifecycle checks..."
"$ROOT_DIR/scripts/vault-dynamic-secrets-check.sh"

echo "Running Nginx proxy readiness checks..."
bash "$ROOT_DIR/scripts/nginx-readiness.sh"

echo "Running audit pipeline checks (Vault + Nginx -> Fluent Bit -> MongoDB)..."
bash "$ROOT_DIR/scripts/audit-pipeline-check.sh"

echo "Core stack started. Running sanity check..."
"$ROOT_DIR/scripts/sanity-check.sh"

echo "Checking Open WebUI availability on http://127.0.0.1:3000 ..."
if ! curl -fsS --max-time 5 "http://127.0.0.1:3000" >/dev/null 2>&1; then
	echo "Open WebUI is not ready yet. Check status/logs with:"
	echo "  ${COMPOSE_CMD[*]} -f $ROOT_DIR/compose.yaml ps"
	echo "  ${COMPOSE_CMD[*]} -f $ROOT_DIR/compose.yaml logs --tail=200 open-webui keycloak"
fi

echo "Done."
