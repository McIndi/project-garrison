terraform {
  required_version = ">= 1.6.0"
}

variable "enabled_secret_engines" {
  type = list(string)
}

variable "dynamic_secret_roles" {
  type = map(object({
    backend     = string
    default_ttl = string
    max_ttl     = string
  }))
}

output "secrets_contract" {
  value = {
    layer                  = "vault-secrets"
    enabled_secret_engines = sort(distinct(var.enabled_secret_engines))
    dynamic_role_names     = sort(keys(var.dynamic_secret_roles))
  }
}
