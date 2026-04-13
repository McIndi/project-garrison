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

variable "class_policy_map" {
  type = map(list(string))
}

locals {
  role_definitions = {
    for class_name, class_cfg in var.agent_classes :
    class_name => {
      token_ttl    = class_cfg.token_ttl
      policy_names = lookup(var.class_policy_map, class_name, [])
    }
  }

  analyst_policy_names = lookup(local.role_definitions, "analyst", { policy_names = [] }).policy_names
}

output "role_definitions" {
  value = local.role_definitions
}

output "analyst_base_only_valid" {
  value = local.analyst_policy_names == ["garrison-base"]
}
