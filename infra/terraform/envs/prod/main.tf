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
  survey_port    = var.survey_port
  panel_port     = var.panel_port

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
  # config/mods.txt no se versiona: si existe en esta PC, viaja a la VM en el primer boot.
  mods_txt = fileexists("${path.module}/../../../../config/mods.txt") ? file("${path.module}/../../../../config/mods.txt") : ""

  # Bot de Discord (encendido on-demand). Con bot_enabled = false no se crea ninguno de sus
  # recursos y el modulo queda igual que antes.
  bot_enabled          = var.bot_enabled
  bot_shape            = var.bot_shape
  bot_ocpus            = var.bot_ocpus
  bot_memory_gb        = var.bot_memory_gb
  discord_bot_token    = var.discord_bot_token
  bot_guild_id         = var.bot_guild_id
  bot_admin_user_ids   = var.bot_admin_user_ids
  bot_allowed_role_ids = var.bot_allowed_role_ids
}
