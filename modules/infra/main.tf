terraform {
  required_version = ">= 1.6.0"
  required_providers {
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

variable "environment" {
  type = string
}

variable "compose_file" {
  type = string
}

variable "services" {
  type = list(string)
}

variable "vault_addr" {
  type        = string
  description = "Vault API address used to verify Vault is reachable before downstream modules run."
}

variable "container_name_prefix" {
  type        = string
  description = "Compose project prefix used to construct expected container names."
}

locals {
  ordered_services = distinct(var.services)
}

# Pre-flight gate: verify Vault is reachable before any downstream Vault provider calls.
# This blocks all dependent modules (vault-core onward) if Vault is not healthy.
resource "null_resource" "vault_health" {
  triggers = {
    vault_addr = var.vault_addr
  }

  provisioner "local-exec" {
    interpreter = ["/bin/sh", "-c"]
    command     = <<-EOT
      set -eu

      health_url="${var.vault_addr}/v1/sys/health"
      max_attempts=10
      max_sleep_seconds=12
      sleep_seconds=1
      attempt=1
      last_code="000"
      last_body=""
      last_error=""

      echo "Checking Vault health at $health_url"
      echo "Policy: success on HTTP 200 (active) or 429 (standby); retry on startup/sealed states (472/473/501/503)."

      vault_host="$(printf '%s' "${var.vault_addr}" | sed -E 's#^[A-Za-z]+://([^/:]+).*#\1#')"
      if command -v getent >/dev/null 2>&1; then
        echo "Host lookup for '$vault_host':"
        getent hosts "$vault_host" || echo "  (no host resolution yet)"
      fi

      while [ "$attempt" -le "$max_attempts" ]; do
        body_file="$(mktemp)"
        err_file="$(mktemp)"

        http_code="$(curl -sS -o "$body_file" -m 4 -w '%%{http_code}' "$health_url" 2>"$err_file" || true)"
        last_code="$http_code"
        last_body="$(tr '\n' ' ' <"$body_file" | head -c 220 || true)"
        last_error="$(tr '\n' ' ' <"$err_file" | head -c 220 || true)"

        rm -f "$body_file" "$err_file"

        case "$http_code" in
          200|429)
            echo "Vault is healthy (HTTP $http_code)."
            exit 0
            ;;
          472|473|501|503)
            echo "Attempt $attempt/$max_attempts: Vault reachable but not healthy yet (HTTP $http_code). body='$${last_body}'"
            ;;
          000)
            echo "Attempt $attempt/$max_attempts: Vault not reachable yet (HTTP 000). curl='$${last_error}'"
            ;;
          *)
            echo "Attempt $attempt/$max_attempts: Vault returned unexpected HTTP $http_code. body='$${last_body}'"
            ;;
        esac

        if [ "$attempt" -eq "$max_attempts" ]; then
          break
        fi

        echo "Retrying in $${sleep_seconds}s..."
        sleep "$sleep_seconds"
        if [ "$sleep_seconds" -lt "$max_sleep_seconds" ]; then
          sleep_seconds=$((sleep_seconds * 2))
          if [ "$sleep_seconds" -gt "$max_sleep_seconds" ]; then
            sleep_seconds="$max_sleep_seconds"
          fi
        fi
        attempt=$((attempt + 1))
      done

      echo "ERROR: Vault did not become healthy at ${var.vault_addr} after $max_attempts attempts." >&2
      echo "Last HTTP code: $last_code" >&2
      echo "Last response body sample: '$last_body'" >&2
      echo "Last curl error sample: '$last_error'" >&2
      exit 1
    EOT
  }
}

output "manifest" {
  value = {
    layer                 = "infra"
    environment           = var.environment
    compose_file          = var.compose_file
    service_count         = length(local.ordered_services)
    services              = local.ordered_services
    container_name_prefix = var.container_name_prefix
  }

  depends_on = [null_resource.vault_health]
}
