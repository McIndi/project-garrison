#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_BOOTSTRAP_RETRIES="${CI_BOOTSTRAP_RETRIES:-2}"
# Set GARRISON_TERRAFORM=true to run bootstrap in Terraform/OpenTofu mode.
# This delegates Vault baseline provisioning to scripts/vault-bootstrap.sh Terraform path.
GARRISON_TERRAFORM="${GARRISON_TERRAFORM:-false}"

if command -v docker >/dev/null 2>&1; then
  COMPOSE_CMD=(docker compose)
elif command -v podman >/dev/null 2>&1; then
  COMPOSE_CMD=(podman compose)
else
  COMPOSE_CMD=()
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

if [[ "${GARRISON_TERRAFORM}" == "true" ]]; then
  echo "=== CI smoke using Terraform/OpenTofu bootstrap path ==="
else
  echo "=== CI smoke using script-managed bootstrap path ==="
fi

if [[ "${CI_INSTALL_DEPS:-false}" == "true" ]]; then
  "$PYTHON_BIN" -m pip install --upgrade pip
  "$PYTHON_BIN" -m pip install -r tool-server/requirements.txt
else
  if ! "$PYTHON_BIN" -c "import fastapi, httpx, pydantic, pymongo, redis, pytest" >/dev/null 2>&1; then
    "$PYTHON_BIN" -m pip install --upgrade pip
    "$PYTHON_BIN" -m pip install -r tool-server/requirements.txt
  fi
fi

run_with_retry "bootstrap" env GARRISON_TERRAFORM="${GARRISON_TERRAFORM}" bash -x scripts/bootstrap.sh

(
  cd "$ROOT_DIR/tool-server"
  "$PYTHON_BIN" -m pytest -q tests
)

(
  cd "$ROOT_DIR/open-webui/pipelines"
  "$PYTHON_BIN" -m pytest -q test_garrison_audit.py
)

echo "CI smoke flow passed"
