# ---------------------------------------------------------------------------------------------
# Identidad y region
# ---------------------------------------------------------------------------------------------

variable "tenancy_ocid" {
  description = "OCID del tenancy (compartment raiz). Sale de ~/.oci/config."
  type        = string
}

variable "region" {
  description = "Region de OCI. La decidida en PLAN.md §4 es Brazil East (Sao Paulo)."
  type        = string
  default     = "sa-saopaulo-1"
}

variable "compartment_name" {
  description = "Nombre del compartment que se crea dentro del tenancy para todo el proyecto."
  type        = string
  default     = "zomboid"
}

variable "name_prefix" {
  description = "Prefijo para el display_name de todos los recursos."
  type        = string
  default     = "zomboid"
}

variable "availability_domain_index" {
  description = "Indice (base 0) del availability domain a usar. Sao Paulo tiene uno solo (AD-1)."
  type        = number
  default     = 0
}

# ---------------------------------------------------------------------------------------------
# Red
# ---------------------------------------------------------------------------------------------

variable "vcn_cidr" {
  description = "CIDR de la VCN."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_cidr" {
  description = "CIDR de la subnet publica donde vive la VM."
  type        = string
  default     = "10.0.1.0/24"
}

variable "admin_cidr" {
  description = <<-EOT
    CIDR desde el que se permite SSH (22/tcp) y RCON (27015/tcp). La IP publica del admin
    con /32, por ejemplo "200.115.1.2/32". Ponerlo en 0.0.0.0/0 abre el SSH al mundo: no.
  EOT
  type        = string

  validation {
    condition     = can(cidrhost(var.admin_cidr, 0))
    error_message = "admin_cidr tiene que ser un CIDR valido, por ejemplo 200.115.1.2/32."
  }
}

variable "game_port" {
  description = "Puerto UDP principal del juego."
  type        = number
  default     = 16261
}

variable "game_udp_port" {
  description = "Segundo puerto UDP del juego (el server usa el rango game_port..game_udp_port)."
  type        = number
  default     = 16262
}

variable "rcon_port" {
  description = "Puerto TCP de RCON. Solo se abre a admin_cidr."
  type        = number
  default     = 27015
}

variable "survey_port" {
  description = <<-EOT
    Puerto TCP de la encuesta de reglas (tools/encuesta). 0 = deshabilitada: no se crea
    ninguna regla de ingress. Con un valor > 0 se abre a 0.0.0.0/0, porque los amigos entran
    desde el celular y no se les puede pedir la IP. Es HTTP plano y sin login: no poner nada
    sensible ahi, y volver a 0 cuando termina la votacion.
  EOT
  type        = number
  default     = 0

  validation {
    condition     = var.survey_port == 0 || (var.survey_port >= 1024 && var.survey_port <= 65535)
    error_message = "survey_port tiene que ser 0 (deshabilitada) o un puerto entre 1024 y 65535."
  }
}

# ---------------------------------------------------------------------------------------------
# Instancia
# ---------------------------------------------------------------------------------------------

variable "shape" {
  description = "Shape de la VM. E5.Flex es la generacion x86 AMD actual en Sao Paulo."
  type        = string
  default     = "VM.Standard.E5.Flex"
}

variable "ocpus" {
  description = "OCPUs de la instancia flex. 1 OCPU = 2 vCPU. 4 OCPU segun PLAN.md §4."
  type        = number
  default     = 4
}

variable "memory_gb" {
  description = "RAM en GB. Tiene que ser >= MAX_MEMORY del heap de la JVM + ~2 GB de sistema."
  type        = number
  default     = 16
}

variable "boot_volume_size_gb" {
  description = "Tamano del boot volume. La imagen de Docker pesa 10.4 GB, mas saves y backups."
  type        = number
  default     = 80

  validation {
    condition     = var.boot_volume_size_gb >= 50
    error_message = "El boot volume tiene que ser de al menos 50 GB (la imagen sola pesa 10.4 GB)."
  }
}

variable "operating_system" {
  description = "Sistema operativo de la imagen a buscar en el catalogo de OCI."
  type        = string
  default     = "Canonical Ubuntu"
}

variable "operating_system_version" {
  description = "Version del SO. 24.04 = Noble Numbat LTS."
  type        = string
  default     = "24.04"
}

variable "ssh_public_key" {
  description = "Clave publica SSH del admin (contenido de ~/.ssh/id_ed25519.pub)."
  type        = string

  validation {
    condition     = can(regex("^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) ", trimspace(var.ssh_public_key)))
    error_message = "ssh_public_key tiene que ser una clave publica OpenSSH completa (ssh-ed25519 AAAA...)."
  }
}

variable "vm_user" {
  description = "Usuario de la VM que corre el server. cloud-init lo crea con docker y sudo."
  type        = string
  default     = "pz"
}

variable "repo_dir" {
  description = "Ruta del clon del repo dentro de la VM."
  type        = string
  default     = "/opt/zomboid-server"
}

variable "repo_url" {
  description = <<-EOT
    URL del repo a clonar en la VM. Acepta dos formas:
      - https://github.com/usuario/repo.git  -> repo publico, clon anonimo, sin deploy key.
      - git@github.com:usuario/repo.git      -> repo privado, clon por SSH; el modulo genera
        una deploy key ed25519 y hay que cargar el output `deploy_public_key` en GitHub.
  EOT
  type        = string
  default     = "https://github.com/lucbece/zomboid-server.git"

  validation {
    condition     = can(regex("^(https://|git@|ssh://)", trimspace(var.repo_url)))
    error_message = "repo_url tiene que empezar con https:// o ser SSH (git@host:usuario/repo.git)."
  }
}

variable "repo_branch" {
  description = "Rama a clonar."
  type        = string
  default     = "main"
}

variable "timezone" {
  description = "Timezone de la VM. Define a que hora local corre el cron de backup."
  type        = string
  default     = "America/Argentina/Buenos_Aires"
}

variable "backup_hour" {
  description = "Hora local (0-23) del backup diario."
  type        = number
  default     = 6
}

# ---------------------------------------------------------------------------------------------
# Config del server de juego (va al .env de la VM, mode 0600)
# ---------------------------------------------------------------------------------------------

variable "admin_username" {
  description = "Usuario admin del juego que crea el server en el primer arranque."
  type        = string
  default     = "admin"
}

variable "admin_password" {
  description = "Password del usuario admin del juego."
  type        = string
  sensitive   = true

  validation {
    # El .env lo parsean bash (source) y docker compose, que no escapan igual. Se acota el
    # juego de caracteres para que no haya forma de romper ninguno de los dos.
    condition     = can(regex("^[A-Za-z0-9._@#%^&*()+=:,/-]{8,64}$", var.admin_password))
    error_message = "La password tiene que tener entre 8 y 64 caracteres y no puede llevar espacios, comillas, backslash ni signo pesos."
  }
}

variable "rcon_password" {
  description = "Password de RCON."
  type        = string
  sensitive   = true

  validation {
    # El .env lo parsean bash (source) y docker compose, que no escapan igual. Se acota el
    # juego de caracteres para que no haya forma de romper ninguno de los dos.
    condition     = can(regex("^[A-Za-z0-9._@#%^&*()+=:,/-]{8,64}$", var.rcon_password))
    error_message = "La password tiene que tener entre 8 y 64 caracteres y no puede llevar espacios, comillas, backslash ni signo pesos."
  }
}

variable "server_password" {
  description = "Password que tienen que poner los jugadores para entrar."
  type        = string
  sensitive   = true

  validation {
    # El .env lo parsean bash (source) y docker compose, que no escapan igual. Se acota el
    # juego de caracteres para que no haya forma de romper ninguno de los dos.
    condition     = can(regex("^[A-Za-z0-9._@#%^&*()+=:,/-]{8,64}$", var.server_password))
    error_message = "La password tiene que tener entre 8 y 64 caracteres y no puede llevar espacios, comillas, backslash ni signo pesos."
  }
}

variable "public_name" {
  description = "Nombre visible del server. Va entre comillas en el .env, asi que no puede llevarlas."
  type        = string
  default     = "Mi server de Zomboid"

  validation {
    condition     = can(regex("^[^\"\\\\$]{1,64}$", var.public_name))
    error_message = "public_name no puede contener comillas dobles, backslash ni signo pesos."
  }
}

variable "max_players" {
  description = "Jugadores simultaneos maximos."
  type        = number
  default     = 16
}

variable "max_memory" {
  description = "Heap maximo de la JVM. 8g para 8 jugadores, 12g para 16 (con memory_gb=16)."
  type        = string
  default     = "12g"
}

variable "min_memory" {
  description = "Heap minimo de la JVM."
  type        = string
  default     = "2048m"
}

# ---------------------------------------------------------------------------------------------
# Backups y presupuesto
# ---------------------------------------------------------------------------------------------

variable "bucket_name" {
  description = "Nombre del bucket de Object Storage para los backups."
  type        = string
  default     = "zomboid-backups"
}

variable "backup_retention_days" {
  description = "Dias que sobrevive un backup en el bucket antes de que la lifecycle rule lo borre."
  type        = number
  default     = 30
}

variable "budget_usd" {
  description = "Presupuesto mensual en USD sobre el que se disparan las alertas."
  type        = number
  default     = 25
}

variable "alert_email" {
  description = "Mail que recibe las alertas de presupuesto."
  type        = string
}

variable "enable_budget" {
  description = <<-EOT
    Crear el budget y sus alert rules. Requiere permisos sobre el tenancy raiz; si la cuenta
    todavia no los tiene, poner false y crear el budget a mano desde la consola.
  EOT
  type        = bool
  default     = true
}
