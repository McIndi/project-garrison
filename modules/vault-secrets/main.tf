terraform {
  required_version = ">= 1.6.0"
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

variable "enabled_secret_engines" {
  type = list(string)
}

variable "dynamic_secret_roles" {
  type = map(object({
    backend     = string
    default_ttl = string
    max_ttl     = string
  }))
}

variable "mongo_root_username" {
  type      = string
  sensitive = false # username is not a secret
}

variable "mongo_root_password" {
  type      = string
  sensitive = true
}

variable "valkey_password" {
  type      = string
  sensitive = true
}

# ---- Database secret engine mount ----
resource "vault_mount" "database" {
  path = "database"
  type = "database"
}

# ---- MongoDB connection (management credential for dynamic role creation) ----
# The {{username}}/{{password}} template vars are substituted by Vault at runtime
# with the static root credentials below. Dynamic roles create ephemeral users.
resource "vault_database_secret_backend_connection" "mongo" {
  backend = vault_mount.database.path
  name    = "mongo"
  allowed_roles = [
    "mongo-readonly",
    "mongo-rag-writer",
    "mongo-code-writer",
  ]

  mongodb {
    connection_url = "mongodb://{{username}}:{{password}}@mongo:27017/admin?authSource=admin"
    username       = var.mongo_root_username
    password       = var.mongo_root_password
  }

  # verifying the connection requires MongoDB to be up and accepting auth;
  # set to false so `tofu apply` succeeds even if Mongo is still initialising.
  verify_connection = false
}

# ---- Valkey connection (Redis-compatible; uses redis database plugin) ----
resource "vault_database_secret_backend_connection" "valkey" {
  backend       = vault_mount.database.path
  name          = "valkey"
  allowed_roles = ["valkey-readonly"]

  redis {
    host     = "valkey"
    port     = 6379
    username = "default"
    password = var.valkey_password
    tls      = false
  }

  verify_connection = false
}

# ---- Per-role creation statement lookup ----
# Maps each dynamic role name to the creation statements expected by its database plugin.
# MongoDB roles: JSON-encoded user creation document.
# Valkey roles:  JSON-encoded ACL rule list.
locals {
  role_creation_statements = {
    mongo-readonly    = [jsonencode({ db = "admin", roles = [{ role = "read", db = "admin" }] })]
    mongo-rag-writer  = [jsonencode({ db = "admin", roles = [{ role = "readWrite", db = "admin" }] })]
    mongo-code-writer = [jsonencode({ db = "admin", roles = [{ role = "readWrite", db = "admin" }] })]
    valkey-readonly   = [jsonencode(["~*", "+@read"])]
  }

  # Which Vault DB connection does each role use?
  role_connection = {
    for name, _ in var.dynamic_secret_roles :
    name => startswith(name, "mongo") ? vault_database_secret_backend_connection.mongo.name : vault_database_secret_backend_connection.valkey.name
  }
}

# ---- Dynamic credential roles ----
resource "vault_database_secret_backend_role" "roles" {
  for_each = var.dynamic_secret_roles

  backend             = vault_mount.database.path
  name                = each.key
  db_name             = local.role_connection[each.key]
  creation_statements = lookup(local.role_creation_statements, each.key, [])
  default_ttl         = each.value.default_ttl
  max_ttl             = each.value.max_ttl

  depends_on = [
    vault_database_secret_backend_connection.mongo,
    vault_database_secret_backend_connection.valkey,
  ]
}

output "secrets_contract" {
  value = {
    layer                  = "vault-secrets"
    enabled_secret_engines = sort(distinct(var.enabled_secret_engines))
    dynamic_role_names     = sort(keys(var.dynamic_secret_roles))
  }
}
