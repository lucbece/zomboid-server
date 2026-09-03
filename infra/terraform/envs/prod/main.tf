# Entorno de produccion: el unico que existe. Todo el detalle esta en ../../modules/oci.
#
#   cd infra/terraform/envs/prod
#   cp terraform.tfvars.example terraform.tfvars   # completar (gitignoreado)
#   tofu init && tofu plan && tofu apply
#
# Prerrequisitos manuales de la cuenta OCI: docs/runbook.md.

module "zomboid" {
  source = "../../modules/oci"

  tenancy_ocid = var.tenancy_ocid
  region       = var.region

  admin_cidr     = var.admin_cidr
  ssh_public_key = var.ssh_public_key

  repo_url    = var.repo_url
  repo_branch = var.repo_branch

  ocpus               = var.ocpus
  memory_gb           = var.memory_gb
  boot_volume_size_gb = var.boot_volume_size_gb

  bucket_name   = var.bucket_name
  budget_usd    = var.budget_usd
  enable_budget = var.enable_budget
  alert_email   = var.alert_email

  admin_username  = var.admin_username
  admin_password  = var.admin_password
  rcon_password   = var.rcon_password
  server_password = var.server_password
  public_name     = var.public_name
  max_players     = var.max_players
  max_memory      = var.max_memory
}
