output "public_ip" {
  description = "IP publica reservada de la VM. No cambia entre stop y start."
  value       = oci_core_public_ip.this.ip_address
}

output "ssh_command" {
  description = "Comando para entrar a la VM."
  value       = "ssh ${var.vm_user}@${oci_core_public_ip.this.ip_address}"
}

output "game_address" {
  description = "Lo que ponen los amigos en Favorites del cliente de Project Zomboid."
  value       = "${oci_core_public_ip.this.ip_address}:${var.game_port}"
}

output "instance_ocid" {
  description = "OCID de la instancia. Lo usan scripts/cloud-start.sh y cloud-stop.sh."
  value       = oci_core_instance.this.id
}

output "compartment_ocid" {
  description = "OCID del compartment del proyecto."
  value       = oci_identity_compartment.this.id
}

output "bucket_name" {
  description = "Bucket de Object Storage donde van los backups."
  value       = oci_objectstorage_bucket.backups.name
}

output "bucket_namespace" {
  description = "Namespace de Object Storage del tenancy (lo necesita rclone)."
  value       = data.oci_objectstorage_namespace.this.namespace
}

output "region" {
  description = "Region donde quedo todo."
  value       = var.region
}

output "deploy_public_key" {
  description = <<-EOT
    Clave publica de la deploy key. Vacia si el repo se clona por HTTPS (repo publico).
    Si no esta vacia, cargarla en GitHub en Settings -> Deploy keys -> Add deploy key,
    SIN marcar "Allow write access". Sin ese paso la VM no puede clonar el repo.
  EOT
  value       = local.use_deploy_key ? trimspace(tls_private_key.deploy[0].public_key_openssh) : ""
}

output "use_deploy_key" {
  description = "true si el repo se clona por SSH y hace falta cargar la deploy key en GitHub."
  value       = local.use_deploy_key
}

output "image_id" {
  description = "OCID de la imagen de Ubuntu que se uso para crear la VM."
  value       = data.oci_core_images.ubuntu.images[0].id
}
