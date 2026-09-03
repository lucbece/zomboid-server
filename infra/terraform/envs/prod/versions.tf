terraform {
  required_version = ">= 1.6.0"

  # Estado local a proposito: es un solo operador y el .tfstate esta gitignoreado.
  # Si algun dia hay mas de una persona operando, mover a un backend con locking.

  required_providers {
    oci = {
      source  = "oracle/oci"
      version = "~> 7.29"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.1"
    }
  }
}

# Autenticacion por API key desde ~/.oci/config (ver docs/runbook.md, "Prerrequisitos manuales").
provider "oci" {
  region              = var.region
  config_file_profile = var.oci_config_profile
}
