output "public_ip" {
  description = "IP publica reservada de la VM."
  value       = module.zomboid.public_ip
}

output "ssh_command" {
  description = "Comando para entrar a la VM."
  value       = module.zomboid.ssh_command
}

output "game_address" {
  description = "Direccion que ponen los amigos en el cliente (Favorites -> Add server)."
  value       = module.zomboid.game_address
}

output "instance_ocid" {
  description = "OCID de la instancia (lo leen scripts/cloud-start.sh y cloud-stop.sh)."
  value       = module.zomboid.instance_ocid
}

output "compartment_ocid" {
  description = "OCID del compartment del proyecto."
  value       = module.zomboid.compartment_ocid
}

output "bucket_name" {
  description = "Bucket de backups."
  value       = module.zomboid.bucket_name
}

output "bucket_namespace" {
  description = "Namespace de Object Storage."
  value       = module.zomboid.bucket_namespace
}

output "deploy_public_key" {
  description = "Deploy key publica: cargarla en GitHub (read-only) antes del primer boot. Vacia si el repo es publico."
  value       = module.zomboid.deploy_public_key
}

output "use_deploy_key" {
  description = "true si repo_url es SSH y hace falta cargar la deploy key en GitHub."
  value       = module.zomboid.use_deploy_key
}

# --- Bot de Discord ---------------------------------------------------------------------------

output "bot_enabled" {
  description = "true si existe la instancia del bot de Discord."
  value       = module.zomboid.bot_enabled
}

output "bot_public_ip" {
  description = "IP publica efimera del bot (cambia en cada recreacion; nadie la necesita salvo para SSH)."
  value       = module.zomboid.bot_public_ip
}

output "bot_ssh_command" {
  description = "Comando para entrar a la instancia del bot."
  value       = module.zomboid.bot_ssh_command
}

output "bot_instance_ocid" {
  description = "OCID de la instancia del bot."
  value       = module.zomboid.bot_instance_ocid
}
