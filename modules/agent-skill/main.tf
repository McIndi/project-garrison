terraform {
  required_version = ">= 1.6.0"
  required_providers {
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
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

variable "skill_repo_path" {
  type = string
}

variable "gitea_skills_repo" {
  type        = string
  description = "Gitea repository in owner/repo format (owner/repo) where skill documents are published."
}

variable "gitea_repo_branch" {
  type    = string
  default = "main"
}

variable "gitea_provisioning_enabled" {
  type        = bool
  description = "Enable Gitea skill document publishing. Requires Gitea to be running and the skills repo to exist."
  default     = false
}

variable "gitea_base_url" {
  type        = string
  description = "Base URL of the Gitea instance (e.g. http://localhost:3001)."
  default     = "http://localhost:3001"
}

variable "gitea_token" {
  type        = string
  sensitive   = true
  description = "Gitea personal access token with repo write permission."
  default     = ""
}

locals {
  skill_repo_path = trim(var.skill_repo_path, "/")

  # Expected Gitea file paths for all classes (used in output regardless of provisioning flag).
  rendered_skill_paths = {
    for class_name, _ in var.agent_classes :
    class_name => "${local.skill_repo_path}/${class_name}.md"
  }

  # Only activate Gitea resources when the flag is set.
  active_classes = var.gitea_provisioning_enabled ? var.agent_classes : {}

  # Rendered content map — computed once and used by both local_file and null_resource.
  rendered_content = {
    for class_name, class_cfg in var.agent_classes :
    class_name => templatefile("${path.module}/templates/skill.md.tpl", {
      agent_class  = class_name
      token_ttl    = class_cfg.token_ttl
      capabilities = class_cfg.capabilities
      description  = class_cfg.description
    })
  }
}

# Write rendered skill documents to the local build directory.
# These are always written regardless of gitea_provisioning_enabled, making them
# available for manual review and local skill injection without Gitea.
resource "local_file" "skill_docs" {
  for_each = var.agent_classes

  filename        = "${path.module}/.rendered/${each.key}.md"
  content         = local.rendered_content[each.key]
  file_permission = "0644"
}

# Commit rendered skill documents to Gitea via the REST API.
# Uses curl so no external Gitea Terraform provider is required.
# Gated by gitea_provisioning_enabled — false by default until Gitea + skills repo exist.
resource "null_resource" "gitea_commit" {
  for_each = local.active_classes

  triggers = {
    content_hash = sha256(local.rendered_content[each.key])
  }

  provisioner "local-exec" {
    interpreter = ["/usr/bin/env", "bash", "-euo", "pipefail", "-c"]
    command     = <<-EOT
      FILE_B64=$(base64 -w 0 "${path.module}/.rendered/${each.key}.md")
      FILE_PATH="${local.skill_repo_path}/${each.key}.md"
      REPO="${var.gitea_skills_repo}"
      BASE_URL="${var.gitea_base_url}"
      BRANCH="${var.gitea_repo_branch}"
      TOKEN="${var.gitea_token}"

      # Check if file already exists to decide create vs update.
      HTTP_STATUS=$(curl -s -o /dev/null -w "%%{http_code}" \
        -H "Authorization: token $TOKEN" \
        "$BASE_URL/api/v1/repos/$REPO/contents/$FILE_PATH?ref=$BRANCH")

      if [ "$HTTP_STATUS" = "200" ]; then
        SHA=$(curl -fsS \
          -H "Authorization: token $TOKEN" \
          "$BASE_URL/api/v1/repos/$REPO/contents/$FILE_PATH?ref=$BRANCH" \
          | python3 -c "import sys, json; print(json.load(sys.stdin)['sha'])")
        curl -fsS -X PUT \
          -H "Authorization: token $TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"message\":\"chore(skills): update ${each.key} skill document [terraform]\",\"content\":\"$FILE_B64\",\"sha\":\"$SHA\",\"branch\":\"$BRANCH\"}" \
          "$BASE_URL/api/v1/repos/$REPO/contents/$FILE_PATH" >/dev/null
        echo "Updated ${each.key}.md in Gitea ($REPO)"
      else
        curl -fsS -X POST \
          -H "Authorization: token $TOKEN" \
          -H "Content-Type: application/json" \
          -d "{\"message\":\"chore(skills): create ${each.key} skill document [terraform]\",\"content\":\"$FILE_B64\",\"branch\":\"$BRANCH\"}" \
          "$BASE_URL/api/v1/repos/$REPO/contents/$FILE_PATH" >/dev/null
        echo "Created ${each.key}.md in Gitea ($REPO)"
      fi
    EOT
  }

  depends_on = [local_file.skill_docs]
}

output "skill_contract" {
  value = {
    layer                      = "agent-skill"
    rendered_skill_paths       = local.rendered_skill_paths
    gitea_provisioning_enabled = var.gitea_provisioning_enabled
    gitea_skills_repo          = var.gitea_skills_repo
  }
}
