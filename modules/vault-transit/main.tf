terraform {
  required_version = ">= 1.6.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

variable "transit_keys" {
  type = map(object({
    type       = string
    convergent = bool
  }))
}

# ---- Transit secret engine mount ----
resource "vault_mount" "transit" {
  path = "transit"
  type = "transit"
}

# ---- Encryption keys ----
# agent-payload    — aes256-gcm96, non-convergent: encrypt agent payloads before writing
# shared-memory    — aes256-gcm96, convergent=true: deterministic encryption for dedup
# artifact-signing — ed25519: sign and verify code artifacts (code agents only)
resource "vault_transit_secret_backend_key" "keys" {
  for_each = var.transit_keys

  backend                = vault_mount.transit.path
  name                   = each.key
  type                   = each.value.type
  convergent_encryption  = each.value.convergent
  deletion_allowed       = false
  exportable             = false
  allow_plaintext_backup = false
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
