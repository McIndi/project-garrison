terraform {
  required_version = ">= 1.6.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
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

# ---- Root CA mount ----
resource "vault_mount" "pki_root" {
  path                      = "pki"
  type                      = "pki"
  default_lease_ttl_seconds = 3600
  max_lease_ttl_seconds     = 315360000 # 10 years
}

# ---- Intermediate CA mount ----
resource "vault_mount" "pki_int" {
  path                      = "pki_int"
  type                      = "pki"
  default_lease_ttl_seconds = 3600
  max_lease_ttl_seconds     = 31536000 # 1 year
}

# ---- Root CA certificate ----
resource "vault_pki_secret_backend_root_cert" "root" {
  backend     = vault_mount.pki_root.path
  type        = "internal"
  common_name = "Garrison Root CA"
  ttl         = "315360000"
  format      = "pem"
  key_type    = "rsa"
  key_bits    = 4096
}

# ---- Root CA CRL / issuing URL configuration ----
resource "vault_pki_secret_backend_config_urls" "root" {
  backend                 = vault_mount.pki_root.path
  issuing_certificates    = ["http://vault:8200/v1/pki/ca"]
  crl_distribution_points = ["http://vault:8200/v1/pki/crl"]
}

# ---- Intermediate CA: generate CSR ----
resource "vault_pki_secret_backend_intermediate_cert_request" "int" {
  backend     = vault_mount.pki_int.path
  type        = "internal"
  common_name = "${var.issuing_ca_label} Intermediate CA"
  format      = "pem"
  key_type    = "rsa"
  key_bits    = 4096
}

# ---- Intermediate CA: root signs the CSR ----
resource "vault_pki_secret_backend_root_sign_intermediate" "int" {
  backend     = vault_mount.pki_root.path
  csr         = vault_pki_secret_backend_intermediate_cert_request.int.csr
  common_name = "${var.issuing_ca_label} Intermediate CA"
  ttl         = "31536000"
  format      = "pem_bundle"
}

# ---- Intermediate CA: install the signed certificate ----
resource "vault_pki_secret_backend_intermediate_set_signed" "int" {
  backend     = vault_mount.pki_int.path
  certificate = vault_pki_secret_backend_root_sign_intermediate.int.certificate
}

# ---- Intermediate CA CRL / issuing URL configuration ----
resource "vault_pki_secret_backend_config_urls" "int" {
  backend                 = vault_mount.pki_int.path
  issuing_certificates    = ["http://vault:8200/v1/pki_int/ca"]
  crl_distribution_points = ["http://vault:8200/v1/pki_int/crl"]

  depends_on = [vault_pki_secret_backend_intermediate_set_signed.int]
}

# ---- PKI issuance roles for agent mesh TLS certificates ----
resource "vault_pki_secret_backend_role" "roles" {
  for_each = var.pki_roles

  backend          = vault_mount.pki_int.path
  name             = each.key
  allowed_domains  = each.value.allowed_domains
  allow_subdomains = true
  max_ttl          = each.value.max_ttl
  key_type         = "rsa"
  key_bits         = 2048

  depends_on = [vault_pki_secret_backend_intermediate_set_signed.int]
}

output "pki_contract" {
  value = {
    layer            = "vault-pki"
    issuing_ca_label = var.issuing_ca_label
    role_names       = sort(keys(var.pki_roles))
    root_ca_serial   = vault_pki_secret_backend_root_cert.root.serial_number
    issuing_ca_path  = vault_mount.pki_int.path
  }
}
