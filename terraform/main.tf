# Phase 7 scaffold stack. Module order mirrors SPEC.md.

module "infra" {
  source       = "../modules/infra"
  environment  = var.environment
  compose_file = var.compose_file
  services     = var.core_services
}

module "vault_core" {
  source        = "../modules/vault-core"
  vault_addr    = var.vault_addr
  audit_devices = var.vault_audit_devices
  approle_roles = var.approle_roles
  depends_on    = [module.infra]
}

module "vault_pki" {
  source           = "../modules/vault-pki"
  pki_roles        = var.pki_roles
  issuing_ca_label = var.issuing_ca_label
  depends_on       = [module.vault_core]
}

module "vault_secrets" {
  source                 = "../modules/vault-secrets"
  dynamic_secret_roles   = var.dynamic_secret_roles
  enabled_secret_engines = var.enabled_secret_engines
  depends_on             = [module.vault_pki]
}

module "vault_transit" {
  source       = "../modules/vault-transit"
  transit_keys = var.transit_keys
  depends_on   = [module.vault_secrets]
}

module "vault_policy" {
  source            = "../modules/vault-policy"
  agent_classes     = var.agent_classes
  base_policy_name  = var.base_policy_name
  additive_policies = var.additive_policies
  depends_on        = [module.vault_transit]
}

module "agent_role" {
  source           = "../modules/agent-role"
  agent_classes    = var.agent_classes
  class_policy_map = module.vault_policy.class_policy_map
  depends_on       = [module.vault_policy]
}

module "agent_skill" {
  source          = "../modules/agent-skill"
  agent_classes   = var.agent_classes
  skill_repo_path = var.skill_repo_path
  depends_on      = [module.agent_role]
}
