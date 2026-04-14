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
    command = <<-EOT
      set -e
      echo "Checking Vault health at ${var.vault_addr}/v1/sys/health ..."
      for i in $(seq 1 15); do
        if curl -fsS --max-time 3 "${var.vault_addr}/v1/sys/health" >/dev/null 2>&1; then
          echo "Vault is healthy."
          exit 0
        fi
        echo "Attempt $i/15: Vault not ready, retrying in 2s..."
        sleep 2
      done
      echo "ERROR: Vault did not become healthy at ${var.vault_addr}" >&2
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
