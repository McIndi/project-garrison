#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
GARRISON_TERRAFORM="${GARRISON_TERRAFORM:-false}"
GARRISON_VAULT_TLS="${GARRISON_VAULT_TLS:-true}"
VAULT_SCHEME="http"
if [[ "${GARRISON_VAULT_TLS}" == "true" ]]; then
	VAULT_SCHEME="https"
fi
VAULT_ADDR="${VAULT_ADDR:-${VAULT_SCHEME}://127.0.0.1:8200}"
TOOL_SERVER_VAULT_ADDR="${TOOL_SERVER_VAULT_ADDR:-${VAULT_SCHEME}://vault:8200}"
VAULT_PKI_URL_BASE="${VAULT_PKI_URL_BASE:-${VAULT_SCHEME}://vault:8200}"
GARRISON_VAULT_TLS_DIR="${GARRISON_VAULT_TLS_DIR:-$ROOT_DIR/logs/vault/tls}"
GARRISON_VAULT_CA_FILE="${GARRISON_VAULT_CA_FILE:-$GARRISON_VAULT_TLS_DIR/vault-ca.pem}"
GARRISON_VAULT_INIT_FILE="${GARRISON_VAULT_INIT_FILE:-$ROOT_DIR/logs/vault/init.json}"

ensure_vault_tls_material() {
	local cert_file="$GARRISON_VAULT_TLS_DIR/vault.crt"
	local key_file="$GARRISON_VAULT_TLS_DIR/vault.key"

	if [[ "${GARRISON_VAULT_TLS}" != "true" ]]; then
		export TOOL_SERVER_VAULT_CACERT=""
		export TOOL_SERVER_VAULT_SKIP_VERIFY="false"
		return 0
	fi

	if ! command -v openssl >/dev/null 2>&1; then
		echo "openssl is required when GARRISON_VAULT_TLS=true" >&2
		exit 1
	fi

	mkdir -p "$GARRISON_VAULT_TLS_DIR"

	if [[ -s "$cert_file" && -s "$key_file" ]] && openssl x509 -checkend 86400 -noout -in "$cert_file" >/dev/null 2>&1; then
		echo "Using existing local Vault TLS certificate material."
		if [[ ! -f "$GARRISON_VAULT_CA_FILE" ]]; then
			cp "$cert_file" "$GARRISON_VAULT_CA_FILE"
		fi
	else
		echo "Generating self-signed Vault bootstrap certificate..."
		openssl req -x509 -newkey rsa:4096 -sha256 -nodes \
			-keyout "$key_file" \
			-out "$cert_file" \
			-days 7 \
			-subj "/CN=vault" \
			-addext "subjectAltName=DNS:vault,DNS:localhost,IP:127.0.0.1" \
			-addext "keyUsage=digitalSignature,keyEncipherment" \
			-addext "extendedKeyUsage=serverAuth"
		cp "$cert_file" "$GARRISON_VAULT_CA_FILE"
		chmod 600 "$key_file"
		chmod 644 "$cert_file" "$GARRISON_VAULT_CA_FILE"
	fi

	export CURL_CA_BUNDLE="$GARRISON_VAULT_CA_FILE"
	export VAULT_CACERT="$GARRISON_VAULT_CA_FILE"
	export TOOL_SERVER_VAULT_CACERT="/app/certs/vault/vault-ca.pem"
	export TOOL_SERVER_VAULT_SKIP_VERIFY="false"
}

wait_for_vault_api() {
	echo "Waiting for Vault API readiness..."
	for attempt in $(seq 1 30); do
		vault_http_code="$(curl -sS -o /dev/null --max-time 2 -w '%{http_code}' "${VAULT_ADDR}/v1/sys/health" || true)"
		if [[ "${vault_http_code}" != "000" ]]; then
			return 0
		fi
		if [[ "$attempt" -eq 30 ]]; then
			echo "Vault did not become ready in time"
			exit 1
		fi
		sleep 2
	done
}

ensure_vault_tls_material
export VAULT_ADDR TOOL_SERVER_VAULT_ADDR VAULT_PKI_URL_BASE GARRISON_VAULT_TLS GARRISON_VAULT_TLS_DIR GARRISON_VAULT_CA_FILE

cd "$ROOT_DIR"

if grep -Eiq 'WEBUI_AUTH:\s*"?False"?' "$ROOT_DIR/compose.yaml"; then
	if [[ "${ALLOW_INSECURE_WEBUI_AUTH:-false}" != "true" ]]; then
		echo "Refusing to bootstrap: WEBUI_AUTH is disabled in compose.yaml"
		echo "Set ALLOW_INSECURE_WEBUI_AUTH=true to bypass this check for local troubleshooting."
		exit 1
	fi
	echo "[WARN] Proceeding with insecure Open WebUI auth because ALLOW_INSECURE_WEBUI_AUTH=true"
fi

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

if [[ -z "${TOOL_SERVER_AUDIT_INGEST_TOKEN:-}" ]]; then
	echo "Issuing runtime audit ingest token..."
	TOOL_SERVER_AUDIT_INGEST_TOKEN="$("$ROOT_DIR/scripts/issue-audit-ingest-token.sh")"
	if [[ -z "${TOOL_SERVER_AUDIT_INGEST_TOKEN}" ]]; then
		echo "Failed to generate audit ingest token"
		exit 1
	fi
	export TOOL_SERVER_AUDIT_INGEST_TOKEN
fi

mkdir -p "$ROOT_DIR/logs/nginx"
touch "$ROOT_DIR/logs/nginx/access.log" "$ROOT_DIR/logs/nginx/error.log"
chmod 0777 "$ROOT_DIR/logs/nginx"
chmod 0666 "$ROOT_DIR/logs/nginx/access.log" "$ROOT_DIR/logs/nginx/error.log" || true

echo "Starting core stack..."
TOOL_SERVER_AUDIT_INGEST_TOKEN="${TOOL_SERVER_AUDIT_INGEST_TOKEN}" \
	VAULT_ADDR="${VAULT_ADDR}" \
	GARRISON_VAULT_TLS="${GARRISON_VAULT_TLS}" \
	TOOL_SERVER_VAULT_ADDR="${TOOL_SERVER_VAULT_ADDR}" \
	TOOL_SERVER_VAULT_CACERT="${TOOL_SERVER_VAULT_CACERT:-}" \
	TOOL_SERVER_VAULT_SKIP_VERIFY="${TOOL_SERVER_VAULT_SKIP_VERIFY:-false}" \
	"${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" up -d --build \
	valkey mongo vault beeai-runtime nginx otel-collector keycloak

echo "Preparing Vault audit log path permissions..."
"${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" exec -T -u root vault sh -c 'mkdir -p /vault/logs && touch /vault/logs/audit.log && chown vault:vault /vault/logs /vault/logs/audit.log && chmod 0700 /vault/logs && chmod 0600 /vault/logs/audit.log' || true

wait_for_vault_api

vault_container_env_prefix="VAULT_ADDR=${VAULT_ADDR}"
if [[ "${GARRISON_VAULT_TLS}" == "true" ]]; then
	vault_container_env_prefix="VAULT_ADDR=${VAULT_ADDR} VAULT_CACERT=/vault/tls/vault-ca.pem"
fi

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
		"${vault_container_env_prefix} vault operator init -address=${VAULT_ADDR} -key-shares=1 -key-threshold=1 -format=json" >"${GARRISON_VAULT_INIT_FILE}"
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

if [[ "${GARRISON_VAULT_TLS}" == "true" ]]; then
	echo "Replacing bootstrap Vault certificate with Vault PKI-issued listener material..."
	"$ROOT_DIR/scripts/vault-issue-local-cert.sh"
	echo "Restarting Vault to load rotated TLS certificate..."
	"${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" restart vault
	wait_for_vault_api
	vault_seal_status="$(curl -fsS --max-time 3 "${VAULT_ADDR}/v1/sys/seal-status" || true)"
	if [[ "${vault_seal_status}" == *'"sealed":true'* ]]; then
		echo "Unsealing Vault after TLS certificate rotation..."
		curl -fsS -X POST -H "Content-Type: application/json" \
			-d "{\"key\":\"${UNSEAL_KEY}\"}" \
			"${VAULT_ADDR}/v1/sys/unseal" >/dev/null
	fi
fi

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
	TOOL_SERVER_VAULT_ADDR="${TOOL_SERVER_VAULT_ADDR}" \
	TOOL_SERVER_VAULT_CACERT="${TOOL_SERVER_VAULT_CACERT:-}" \
	TOOL_SERVER_VAULT_SKIP_VERIFY="${TOOL_SERVER_VAULT_SKIP_VERIFY:-false}" \
	TOOL_SERVER_VAULT_TOKEN="${TOOL_SERVER_VAULT_TOKEN_RUNTIME}" \
	"${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" up -d --no-deps tool-server

echo "Starting Open WebUI with runtime-scoped orchestrate token..."
TOOL_SERVER_AUDIT_INGEST_TOKEN="${TOOL_SERVER_AUDIT_INGEST_TOKEN}" \
	TOOL_SERVER_VAULT_ADDR="${TOOL_SERVER_VAULT_ADDR}" \
	TOOL_SERVER_VAULT_CACERT="${TOOL_SERVER_VAULT_CACERT:-}" \
	TOOL_SERVER_VAULT_SKIP_VERIFY="${TOOL_SERVER_VAULT_SKIP_VERIFY:-false}" \
	TOOL_SERVER_VAULT_TOKEN="${TOOL_SERVER_VAULT_TOKEN_RUNTIME}" \
	GARRISON_ORCHESTRATE_BEARER_TOKEN="${OPENWEBUI_ORCH_TOKEN}" \
	"${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" up -d --no-deps open-webui

if [[ -n "${TOOL_SERVER_AUDIT_INGEST_TOKEN:-}" ]]; then
	echo "Starting Fluent Bit after tool-server becomes available..."
	TOOL_SERVER_AUDIT_INGEST_TOKEN="${TOOL_SERVER_AUDIT_INGEST_TOKEN}" \
		"${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" up -d --no-deps fluent-bit
fi

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
