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

variable "skill_repo_path" {
  type = string
}

locals {
  rendered_skill_paths = {
    for class_name, _class_cfg in var.agent_classes :
    class_name => format("%s/%s.md", trim(var.skill_repo_path, "/"), class_name)
  }
}

output "skill_contract" {
  value = {
    layer                = "agent-skill"
    rendered_skill_paths = local.rendered_skill_paths
  }
}
