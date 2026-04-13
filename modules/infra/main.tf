terraform {
  required_version = ">= 1.6.0"
}

variable "environment" {
  type = string
}

variable "compose_file" {
  type = string
}

variable "services" {
  type = list(string)
}

locals {
  ordered_services = distinct(var.services)
}

output "manifest" {
  value = {
    layer         = "infra"
    environment   = var.environment
    compose_file  = var.compose_file
    service_count = length(local.ordered_services)
    services      = local.ordered_services
  }
}
