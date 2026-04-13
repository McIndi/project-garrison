variable "environment" {
  description = "Deployment environment label."
  type        = string
  default     = "local"
}

variable "compose_file" {
  description = "Compose manifest path used by local runtime bootstrap."
  type        = string
  default     = "compose.yaml"
}

variable "core_services" {
  description = "Core services expected in local runtime bootstrap order."
  type        = list(string)
  default = [
    "valkey",
    "mongo",
    "vault",
    "beeai-runtime",
    "otel-collector",
    "tool-server",
    "keycloak",
    "open-webui",
  ]
}

variable "vault_addr" {
  description = "Vault service endpoint for module references."
  type        = string
  default     = "http://vault:8200"
}

variable "vault_audit_devices" {
  description = "Audit devices to configure in Vault core layer."
  type = map(object({
    type = string
    path = string
  }))
  default = {
    file = {
      type = "file"
      path = "/vault/logs/audit.log"
    }
    syslog = {
      type = "syslog"
      path = "AUTH"
    }
  }
}

variable "approle_roles" {
  description = "Core AppRole definitions for runtime agent classes."
  type = map(object({
    token_ttl     = string
    token_max_ttl = string
  }))
  default = {
    orchestrator = {
      token_ttl     = "4h"
      token_max_ttl = "4h"
    }
    code = {
      token_ttl     = "2h"
      token_max_ttl = "2h"
    }
    rag = {
      token_ttl     = "1h"
      token_max_ttl = "1h"
    }
    analyst = {
      token_ttl     = "1h"
      token_max_ttl = "1h"
    }
  }
}

variable "agent_classes" {
  description = "Agent class definitions for downstream role/policy/skill modules."
  type = map(object({
    capabilities = list(string)
    token_ttl    = string
    description  = string
  }))
  default = {
    orchestrator = {
      capabilities = ["base", "orchestrate"]
      token_ttl    = "4h"
      description  = "Tier 1 query handler. Plans tool use, delegates, manages handoffs."
    }
    rag = {
      capabilities = ["base", "rag"]
      token_ttl    = "1h"
      description  = "Retrieval agent. Reads source docs, writes structured summaries."
    }
    code = {
      capabilities = ["base", "code"]
      token_ttl    = "2h"
      description  = "Code generation agent. Reads and commits to Gitea."
    }
    analyst = {
      capabilities = ["base"]
      token_ttl    = "1h"
      description  = "Read-only analysis. Reads shared memory, writes findings only."
    }
  }
}

variable "transit_keys" {
  description = "Vault transit keyring specification."
  type = map(object({
    type       = string
    convergent = bool
  }))
  default = {
    agent-payload = {
      type       = "aes256-gcm96"
      convergent = false
    }
    shared-memory = {
      type       = "aes256-gcm96"
      convergent = true
    }
    artifact-signing = {
      type       = "ed25519"
      convergent = false
    }
  }
}

variable "enabled_secret_engines" {
  description = "Dynamic secret engines enabled for runtime."
  type        = list(string)
  default     = ["database"]
}

variable "dynamic_secret_roles" {
  description = "Dynamic roles expected for MongoDB and Valkey."
  type = map(object({
    backend     = string
    default_ttl = string
    max_ttl     = string
  }))
  default = {
    mongo-readonly = {
      backend     = "database"
      default_ttl = "1h"
      max_ttl     = "24h"
    }
    mongo-rag-writer = {
      backend     = "database"
      default_ttl = "1h"
      max_ttl     = "24h"
    }
    mongo-code-writer = {
      backend     = "database"
      default_ttl = "1h"
      max_ttl     = "24h"
    }
    valkey-readonly = {
      backend     = "database"
      default_ttl = "1h"
      max_ttl     = "24h"
    }
  }
}

variable "base_policy_name" {
  description = "Base policy name applied to all classes."
  type        = string
  default     = "garrison-base"
}

variable "additive_policies" {
  description = "Optional additive policy mapping by class."
  type        = map(list(string))
  default = {
    orchestrator = ["garrison-orchestrator"]
    rag          = ["garrison-rag"]
    code         = ["garrison-code"]
    analyst      = []
  }
}

variable "pki_roles" {
  description = "PKI role contracts for agent mesh certificates."
  type = map(object({
    allowed_domains = list(string)
    max_ttl         = string
  }))
  default = {
    agent-mesh = {
      allowed_domains = ["garrison.local"]
      max_ttl         = "24h"
    }
  }
}

variable "issuing_ca_label" {
  description = "Friendly label for issuing CA reference."
  type        = string
  default     = "garrison-intermediate"
}

variable "skill_repo_path" {
  description = "Repository path where rendered skill docs are published."
  type        = string
  default     = "skills"
}
