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
  description = "Deploy key publica: cargarla en GitHub (read-only) antes del primer boot."
  value       = module.zomboid.deploy_public_key
}
