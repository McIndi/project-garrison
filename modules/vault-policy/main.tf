terraform {
  required_version = ">= 1.6.0"
}

variable "agent_classes" {
  type = map(object({
    capabilities = list(string)
    token_ttl    = string
    description  = string
  }))
}

variable "base_policy_name" {
  type = string
}

variable "additive_policies" {
  type = map(list(string))
}

locals {
  class_policy_map = {
    for class_name, _class_cfg in var.agent_classes :
    class_name => concat([var.base_policy_name], lookup(var.additive_policies, class_name, []))
  }
}

output "class_policy_map" {
  value = local.class_policy_map
}

output "policy_contract" {
  value = {
    layer            = "vault-policy"
    base_policy_name = var.base_policy_name
    class_policy_map = local.class_policy_map
  }
}
