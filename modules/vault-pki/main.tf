terraform {
  required_version = ">= 1.6.0"
}

variable "pki_roles" {
  type = map(object({
    allowed_domains = list(string)
    max_ttl         = string
  }))
}

variable "issuing_ca_label" {
  type = string
}

output "pki_contract" {
  value = {
    layer            = "vault-pki"
    issuing_ca_label = var.issuing_ca_label
    role_names       = sort(keys(var.pki_roles))
  }
}
