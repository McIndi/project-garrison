#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -n "${PYTHON_CMD:-}" ]]; then
  PYTHON_BIN="${PYTHON_CMD}"
elif [[ -x "$ROOT_DIR/.venv/bin/python" ]]; then
  PYTHON_BIN="$ROOT_DIR/.venv/bin/python"
else
  PYTHON_BIN="python3"
fi

cleanup() {
  if command -v docker >/dev/null 2>&1; then
    docker compose -f "$ROOT_DIR/compose.yaml" down -v --remove-orphans || true
  elif command -v podman >/dev/null 2>&1; then
    podman compose -f "$ROOT_DIR/compose.yaml" down -v --remove-orphans || true
  fi
}
trap cleanup EXIT

cd "$ROOT_DIR"

bash scripts/bootstrap.sh

if [[ "${CI_INSTALL_DEPS:-false}" == "true" ]]; then
  "$PYTHON_BIN" -m pip install --upgrade pip
  "$PYTHON_BIN" -m pip install -r tool-server/requirements.txt
else
  if ! "$PYTHON_BIN" -c "import fastapi, httpx, pydantic, pymongo, redis, pytest" >/dev/null 2>&1; then
    "$PYTHON_BIN" -m pip install --upgrade pip
    "$PYTHON_BIN" -m pip install -r tool-server/requirements.txt
  fi
fi

(
  cd "$ROOT_DIR/tool-server"
  "$PYTHON_BIN" -m pytest -q tests
)

(
  cd "$ROOT_DIR/open-webui/pipelines"
  "$PYTHON_BIN" -m pytest -q test_garrison_audit.py
)

echo "CI smoke flow passed"
