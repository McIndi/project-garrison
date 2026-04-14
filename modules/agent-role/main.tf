terraform {
  required_version = ">= 1.6.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

variable "agent_classes" {
  type = map(object({
    capabilities = list(string)
    token_ttl    = number
    description  = string
  }))
}

variable "class_policy_map" {
  type = map(list(string))
}

# One AppRole role per agent class.
# SPEC constraint: secret_id_num_uses = 1 (one-time secret-ids, never stored in state).
# Role-ids are stable identifiers and safe to include in outputs.
resource "vault_approle_auth_backend_role" "roles" {
  for_each = var.agent_classes

  backend            = "approle"
  role_name          = each.key
  token_ttl          = each.value.token_ttl
  token_max_ttl      = each.value.token_ttl
  secret_id_num_uses = 1
  secret_id_ttl      = 1800 # 30 minutes in seconds
  token_policies     = lookup(var.class_policy_map, each.key, [])
}

locals {
  role_definitions = {
    for class_name, class_cfg in var.agent_classes :
    class_name => {
      token_ttl    = class_cfg.token_ttl
      policy_names = lookup(var.class_policy_map, class_name, [])
      role_id      = vault_approle_auth_backend_role.roles[class_name].role_id
    }
  }

  analyst_policy_names = lookup(
    { for k, v in local.role_definitions : k => v.policy_names },
    "analyst",
    []
  )
}

# role_definitions includes stable role_ids — safe to output (not secret-ids).
output "role_definitions" {
  value = local.role_definitions
}

# Invariant assertion: analyst class must only have the base policy (no additive).
output "analyst_base_only_valid" {
  value = local.analyst_policy_names == ["garrison-base"]
}
