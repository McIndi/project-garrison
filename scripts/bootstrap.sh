#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$ROOT_DIR"

if command -v docker >/dev/null 2>&1; then
	COMPOSE_CMD=(docker compose)
elif command -v podman >/dev/null 2>&1; then
	COMPOSE_CMD=(podman compose)
else
	echo "Neither docker nor podman is available"
	exit 1
fi

echo "Starting core stack..."
"${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" up -d --build \
	valkey mongo vault beeai-runtime otel-collector tool-server keycloak open-webui

echo "Configuring Vault baseline for dynamic/auditable secrets..."
"$ROOT_DIR/scripts/vault-bootstrap.sh"

echo "Running Vault readiness checks..."
"$ROOT_DIR/scripts/vault-readiness.sh"

echo "Running Vault policy matrix checks..."
"$ROOT_DIR/scripts/vault-policy-check.sh"

echo "Running Vault dynamic secrets lifecycle checks..."
"$ROOT_DIR/scripts/vault-dynamic-secrets-check.sh"

echo "Core stack started. Running sanity check..."
"$ROOT_DIR/scripts/sanity-check.sh"

echo "Checking Open WebUI availability on http://127.0.0.1:3000 ..."
if ! curl -fsS --max-time 5 "http://127.0.0.1:3000" >/dev/null 2>&1; then
	echo "Open WebUI is not ready yet. Check status/logs with:"
	echo "  ${COMPOSE_CMD[*]} -f $ROOT_DIR/compose.yaml ps"
	echo "  ${COMPOSE_CMD[*]} -f $ROOT_DIR/compose.yaml logs --tail=200 open-webui keycloak"
fi

echo "Done."
