output "phase7_contract_summary" {
  value = {
    infra         = module.infra.manifest
    vault_core    = module.vault_core.core_contract
    vault_pki     = module.vault_pki.pki_contract
    vault_secrets = module.vault_secrets.secrets_contract
    vault_transit = module.vault_transit.transit_contract
    vault_policy  = module.vault_policy.policy_contract
    agent_role = {
      role_definitions        = module.agent_role.role_definitions
      analyst_base_only_valid = module.agent_role.analyst_base_only_valid
    }
    agent_skill = module.agent_skill.skill_contract
  }
}
