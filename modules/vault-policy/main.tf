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

variable "base_policy_name" {
  type = string
}

variable "additive_policies" {
  type = map(list(string))
}

locals {
  # Full policy assignment per class: base + any additive policies.
  # analyst class gets only the base policy (no additive template exists for it).
  class_policy_map = {
    for class_name, _class_cfg in var.agent_classes :
    class_name => concat([var.base_policy_name], lookup(var.additive_policies, class_name, []))
  }

  # All unique policy names that must be created in Vault.
  # Includes base + all additive policies + the fixed tool-server service identity policy.
  all_policy_names = toset(concat(
    [var.base_policy_name, "garrison-tool-server"],
    flatten(values(var.additive_policies))
  ))

  # Maps each policy name to its HCL template file.
  policy_template_map = {
    "garrison-base"         = "${path.module}/templates/base-agent.hcl.tpl"
    "garrison-orchestrator" = "${path.module}/templates/orchestrator.hcl.tpl"
    "garrison-rag"          = "${path.module}/templates/rag-agent.hcl.tpl"
    "garrison-code"         = "${path.module}/templates/code-agent.hcl.tpl"
    "garrison-tool-server"  = "${path.module}/templates/tool-server.hcl.tpl"
  }
}

# Create every policy in Vault. The for_each set is computed from the
# class_policy_map so adding a new agent class automatically provisions its policy.
resource "vault_policy" "policies" {
  for_each = local.all_policy_names

  name = each.key

  lifecycle {
    precondition {
      condition     = contains(keys(local.policy_template_map), each.key)
      error_message = "No template exists for Vault policy '${each.key}'. Add it to local.policy_template_map (modules/vault-policy/main.tf) and create the corresponding templates/*.hcl.tpl file."
    }
  }

  policy = templatefile(local.policy_template_map[each.key], {})
}

output "class_policy_map" {
  value = local.class_policy_map
}

output "policy_contract" {
  value = {
    layer            = "vault-policy"
    base_policy_name = var.base_policy_name
    class_policy_map = local.class_policy_map
    policy_names     = sort(tolist(local.all_policy_names))
  }

  depends_on = [vault_policy.policies]
}
