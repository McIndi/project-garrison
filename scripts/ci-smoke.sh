#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_BOOTSTRAP_RETRIES="${CI_BOOTSTRAP_RETRIES:-2}"
# Set GARRISON_TERRAFORM=true to use OpenTofu for Vault configuration instead of
# vault-bootstrap.sh. Runs tofu apply then uses the existing check scripts as parity gates.
GARRISON_TERRAFORM="${GARRISON_TERRAFORM:-false}"

if command -v docker >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v podman >/dev/null 2>&1; then
  COMPOSE_CMD=(podman compose)
else
  COMPOSE_CMD=()
fi

# Detect OpenTofu or Terraform binary for GARRISON_TERRAFORM path.
if command -v tofu >/dev/null 2>&1; then
  TOFU_CMD=tofu
elif command -v terraform >/dev/null 2>&1; then
  TOFU_CMD=terraform
else
  TOFU_CMD=""
fi

if [[ -n "${PYTHON_CMD:-}" ]]; then
  PYTHON_BIN="${PYTHON_CMD}"
elif [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
  PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
else
  PYTHON_BIN="python3"
fi

cleanup() {
  if [[ "${#COMPOSE_CMD[@]}" -gt 0 ]]; then
    "${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" down -v --remove-orphans || true
  fi
}

dump_runtime_diagnostics() {
  echo "Smoke script failed. Dumping container diagnostics..."
  if command -v docker >/dev/null 2>&1; then
    docker ps -a || true
  fi
  if command -v podman >/dev/null 2>&1; then
    podman ps -a || true
  fi
  if [[ "${#COMPOSE_CMD[@]}" -gt 0 ]]; then
    "${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" ps || true
    "${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" logs || true
  fi
}

on_fail() {
  local line_no="$1"
  local cmd="$2"
  echo "[ERROR] ci-smoke failed at line ${line_no}: ${cmd}" >&2
  dump_runtime_diagnostics
}

run_with_retry() {
  local label="$1"
  shift
  local attempt
  for attempt in $(seq 1 "$CI_BOOTSTRAP_RETRIES"); do
    echo "Running ${label} (attempt ${attempt}/${CI_BOOTSTRAP_RETRIES})"
    if "$@"; then
      return 0
    fi
    if [[ "$attempt" -lt "$CI_BOOTSTRAP_RETRIES" ]]; then
      echo "${label} failed, retrying after cleanup..."
      cleanup
      sleep 3
    fi
  done
  echo "${label} failed after ${CI_BOOTSTRAP_RETRIES} attempts"
  return 1
}

trap 'on_fail "$LINENO" "$BASH_COMMAND"' ERR
trap cleanup EXIT

cd "$ROOT_DIR"

# ---------------------------------------------------------------------------
# Terraform parity path: bring up compose core, run tofu apply, then validate.
# ---------------------------------------------------------------------------
if [[ "${GARRISON_TERRAFORM}" == "true" ]]; then
  if [[ -z "${TOFU_CMD}" ]]; then
    echo "[ERROR] GARRISON_TERRAFORM=true but neither 'tofu' nor 'terraform' is installed." >&2
    exit 1
  fi

  echo "=== GARRISON_TERRAFORM mode: OpenTofu-backed Vault provisioning ==="

  if [[ "${#COMPOSE_CMD[@]}" -gt 0 ]]; then
    echo "Starting core compose services (containers only — Vault config handled by Terraform)..."
    TOOL_SERVER_AUDIT_INGEST_TOKEN="${TOOL_SERVER_AUDIT_INGEST_TOKEN:-placeholder}" \
      "${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" up -d --build \
        valkey mongo vault beeai-runtime nginx fluent-bit otel-collector keycloak

    echo "Preparing Vault audit log path permissions..."
    "${COMPOSE_CMD[@]}" -f "$ROOT_DIR/compose.yaml" exec -T -u root vault sh -c \
      'mkdir -p /vault/logs && touch /vault/logs/audit.log && chown vault:vault /vault/logs /vault/logs/audit.log && chmod 0700 /vault/logs && chmod 0600 /vault/logs/audit.log' || true

    echo "Waiting for Vault API readiness..."
    for attempt in $(seq 1 30); do
      if curl -fsS --max-time 2 "http://127.0.0.1:8200/v1/sys/health" >/dev/null 2>&1; then
        break
      fi
      if [[ "$attempt" -eq 30 ]]; then
        echo "[ERROR] Vault did not become ready in time." >&2
        exit 1
      fi
      sleep 2
    done
  fi

  echo "Running: ${TOFU_CMD} -chdir=terraform init -backend=false"
  "${TOFU_CMD}" -chdir=terraform init -backend=false

  export VAULT_ADDR="${VAULT_ADDR:-http://127.0.0.1:8200}"
  export VAULT_TOKEN="${VAULT_TOKEN:-root}"

  echo "Running: ${TOFU_CMD} -chdir=terraform apply -auto-approve"
  "${TOFU_CMD}" -chdir=terraform apply -auto-approve \
    -var="mongo_root_password=${MONGO_ROOT_PASSWORD:-rootpass}" \
    -var="valkey_password=${VALKEY_PASSWORD:-rootpass}"

  echo "--- Terraform applied. Running parity validation scripts ---"
  bash "$ROOT_DIR/scripts/vault-readiness.sh"
  bash "$ROOT_DIR/scripts/vault-policy-check.sh"
  bash "$ROOT_DIR/scripts/vault-dynamic-secrets-check.sh"

  if [[ "${CI_INSTALL_DEPS:-false}" == "true" ]]; then
    "$PYTHON_BIN" -m pip install --upgrade pip
    "$PYTHON_BIN" -m pip install -r tool-server/requirements.txt
  fi

  (
    cd "$ROOT_DIR/tool-server"
    "$PYTHON_BIN" -m pytest -q tests
  )

  (
    cd "$ROOT_DIR/open-webui/pipelines"
    "$PYTHON_BIN" -m pytest -q test_garrison_audit.py
  )

  echo "=== Terraform parity smoke passed ==="
  exit 0
fi
# ---------------------------------------------------------------------------
# Default path: existing script-based bootstrap (vault-bootstrap.sh).
# ---------------------------------------------------------------------------

if [[ "${CI_INSTALL_DEPS:-false}" == "true" ]]; then
  "$PYTHON_BIN" -m pip install --upgrade pip
  "$PYTHON_BIN" -m pip install -r tool-server/requirements.txt
else
  if ! "$PYTHON_BIN" -c "import fastapi, httpx, pydantic, pymongo, redis, pytest" >/dev/null 2>&1; then
    "$PYTHON_BIN" -m pip install --upgrade pip
    "$PYTHON_BIN" -m pip install -r tool-server/requirements.txt
  fi
fi

run_with_retry "bootstrap" bash -x scripts/bootstrap.sh

(
  cd "$ROOT_DIR/tool-server"
  "$PYTHON_BIN" -m pytest -q tests
)

(
  cd "$ROOT_DIR/open-webui/pipelines"
  "$PYTHON_BIN" -m pytest -q test_garrison_audit.py
)

echo "CI smoke flow passed"
