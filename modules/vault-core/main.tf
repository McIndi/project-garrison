terraform {
  required_version = ">= 1.6.0"
}

variable "vault_addr" {
  type = string
}

variable "audit_devices" {
  type = map(object({
    type = string
    path = string
  }))
}

variable "approle_roles" {
  type = map(object({
    token_ttl     = string
    token_max_ttl = string
  }))
}

output "core_contract" {
  value = {
    layer              = "vault-core"
    vault_addr         = var.vault_addr
    audit_device_names = sort(keys(var.audit_devices))
    approle_role_names = sort(keys(var.approle_roles))
  }
}
