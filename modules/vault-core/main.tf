terraform {
  required_version = ">= 1.6.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
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

# Audit devices: file audit writes to the volume-mounted path; syslog audit routes via AUTH.
# The var.audit_devices map key becomes the Vault mount path (e.g. "file", "syslog").
# The var.audit_devices.path field is:
#   - For type="file":   the file_path option value (/vault/logs/audit.log)
#   - For type="syslog": the facility option value (AUTH)
resource "vault_audit" "devices" {
  for_each = var.audit_devices

  type = each.value.type
  path = each.key

  options = each.value.type == "file" ? {
    file_path = each.value.path
    } : {
    tag      = "garrison-vault"
    facility = each.value.path
  }
}

# AppRole auth mount. Agents authenticate via role-id + one-time secret-id.
# Human identity is Keycloak OIDC — these auth methods are intentionally separate.
resource "vault_auth_backend" "approle" {
  type = "approle"
  path = "approle"

  depends_on = [vault_audit.devices]
}

output "core_contract" {
  value = {
    layer              = "vault-core"
    vault_addr         = var.vault_addr
    audit_device_names = sort(keys(var.audit_devices))
    approle_role_names = sort(keys(var.approle_roles))
  }
}
