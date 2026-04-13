terraform {
  required_version = ">= 1.6.0"
}

variable "transit_keys" {
  type = map(object({
    type       = string
    convergent = bool
  }))
}

locals {
  convergent_key_names = sort([
    for name, key in var.transit_keys : name if key.convergent
  ])
}

output "transit_contract" {
  value = {
    layer                = "vault-transit"
    key_names            = sort(keys(var.transit_keys))
    convergent_key_names = local.convergent_key_names
  }
}
