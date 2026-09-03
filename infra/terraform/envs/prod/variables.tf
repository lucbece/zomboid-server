variable "tenancy_ocid" {
  description = "OCID del tenancy. Es la linea 'tenancy=' de ~/.oci/config."
  type        = string
}

variable "oci_config_profile" {
  description = "Perfil de ~/.oci/config a usar."
  type        = string
  default     = "DEFAULT"
}

variable "region" {
  description = "Region de OCI. Brazil East (Sao Paulo) se elige al crear la cuenta de OCI; ver docs/deploy-oracle.md."
  type        = string
  default     = "sa-saopaulo-1"
}

variable "admin_cidr" {
  description = "IP publica del admin en /32. Se abre SSH y RCON solo a este CIDR."
  type        = string
}

variable "survey_port" {
  description = "Puerto de la encuesta de reglas (tools/encuesta). 0 = cerrada. Ver docs/survey.md."
  type        = number
  default     = 0
}

variable "ssh_public_key" {
  description = "Clave publica SSH del admin (contenido de ~/.ssh/id_ed25519.pub)."
  type        = string
}

variable "alert_email" {
  description = "Mail que recibe las alertas de presupuesto."
  type        = string
}

variable "repo_url" {
  description = <<-EOT
    Repo a clonar en la VM. https://... = repo publico (clon anonimo, sin deploy key);
    git@host:usuario/repo.git = repo privado (clon por SSH con la deploy key que genera Tofu).
  EOT
  type        = string
  default     = "https://github.com/lucbece/zomboid-server.git"
}

variable "repo_branch" {
  description = "Rama a clonar."
  type        = string
  default     = "main"
}

variable "ocpus" {
  description = "OCPUs de la VM."
  type        = number
  default     = 4
}

variable "memory_gb" {
  description = "RAM de la VM en GB."
  type        = number
  default     = 16
}

variable "boot_volume_size_gb" {
  description = "Boot volume en GB."
  type        = number
  default     = 80
}

variable "budget_usd" {
  description = "Presupuesto mensual en USD."
  type        = number
  default     = 25
}

variable "enable_budget" {
  description = "Crear el budget. Requiere permisos sobre el tenancy raiz."
  type        = bool
  default     = true
}

variable "bucket_name" {
  description = "Bucket de backups. Tiene que ser unico dentro del namespace del tenancy."
  type        = string
  default     = "zomboid-backups"
}

# --- Config del server de juego (termina en el .env de la VM) --------------------------------

variable "admin_username" {
  description = "Usuario admin del juego."
  type        = string
  default     = "admin"
}

variable "admin_password" {
  description = "Password del usuario admin del juego."
  type        = string
  sensitive   = true
}

variable "rcon_password" {
  description = "Password de RCON."
  type        = string
  sensitive   = true
}

variable "server_password" {
  description = "Password que ponen los jugadores para entrar."
  type        = string
  sensitive   = true
}

variable "public_name" {
  description = "Nombre visible del server."
  type        = string
  default     = "Mi server de Zomboid"
}

variable "max_players" {
  description = "Jugadores simultaneos maximos."
  type        = number
  default     = 16
}

variable "max_memory" {
  description = "Heap maximo de la JVM (8g para 8 jugadores, 12g para 16)."
  type        = string
  default     = "12g"
}
