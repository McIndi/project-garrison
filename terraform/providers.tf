# Provider configuration for Project Garrison.
#
# Credentials are read from environment variables — never hardcode them here.
#
# Required environment variables:
#   VAULT_ADDR      — e.g. http://127.0.0.1:8200
#   VAULT_TOKEN     — e.g. root (dev mode) or a scoped bootstrap token
#   DOCKER_HOST     — Podman: unix:///run/user/$(id -u)/podman/podman.sock
#                     Docker: unix:///var/run/docker.sock
#   GITEA_BASE_URL  — e.g. http://localhost:3001
#   GITEA_TOKEN     — personal access token with repo write permission

# Vault / OpenBao provider. Reads VAULT_ADDR and VAULT_TOKEN from environment.
provider "vault" {}

# Container engine provider. Reads DOCKER_HOST from environment.
# Works with both Docker and Podman (via compatibility socket).
provider "docker" {}

