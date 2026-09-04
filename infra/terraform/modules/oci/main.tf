# ---------------------------------------------------------------------------------------------
# Modulo OCI del servidor de Project Zomboid.
#
# Crea: compartment, VCN + subnet publica + IGW + route table, NSG, instancia E5.Flex con
# cloud-init, IP publica RESERVED (sobrevive stop/start), bucket de backups con lifecycle,
# dynamic group + policy para instance principal, y budget con alertas.
#
# Ver docs/runbook.md para los prerrequisitos manuales de la cuenta.
# ---------------------------------------------------------------------------------------------

locals {
  name = var.name_prefix

  # El juego usa dos puertos UDP contiguos; se abren como rango.
  game_port_min = min(var.game_port, var.game_udp_port)
  game_port_max = max(var.game_port, var.game_udp_port)

  # Un repo publico se clona por HTTPS sin credenciales: no hace falta deploy key y no queda
  # ninguna clave privada en la VM. Un repo privado se clona por SSH (git@... o ssh://...) y
  # ahi si hace falta la deploy key que genera este modulo.
  use_deploy_key = !startswith(lower(trimspace(var.repo_url)), "https://")
}

# ---------------------------------------------------------------------------------------------
# Compartment
# ---------------------------------------------------------------------------------------------

resource "oci_identity_compartment" "this" {
  compartment_id = var.tenancy_ocid
  name           = var.compartment_name
  description    = "Servidor dedicado de Project Zomboid B42 (repo zomboid-server)"

  # Sin esto `tofu destroy` deja el compartment huerfano en estado ACTIVE.
  enable_delete = true
}

data "oci_identity_availability_domains" "this" {
  compartment_id = var.tenancy_ocid
}

data "oci_objectstorage_namespace" "this" {
  compartment_id = var.tenancy_ocid
}

# Ubuntu 24.04 mas reciente publicada por Canonical para este shape.
# sort_by/sort_order + [0] = la ultima build; el catalogo de OCI publica una imagen nueva por mes.
data "oci_core_images" "ubuntu" {
  compartment_id           = var.tenancy_ocid
  operating_system         = var.operating_system
  operating_system_version = var.operating_system_version
  shape                    = var.shape
  state                    = "AVAILABLE"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# ---------------------------------------------------------------------------------------------
# Red
# ---------------------------------------------------------------------------------------------

resource "oci_core_vcn" "this" {
  compartment_id = oci_identity_compartment.this.id
  cidr_blocks    = [var.vcn_cidr]
  display_name   = "${local.name}-vcn"
  dns_label      = "zomboid"
}

resource "oci_core_internet_gateway" "this" {
  compartment_id = oci_identity_compartment.this.id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name}-igw"
  enabled        = true
}

resource "oci_core_route_table" "public" {
  compartment_id = oci_identity_compartment.this.id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name}-rt-public"

  route_rules {
    destination       = "0.0.0.0/0"
    destination_type  = "CIDR_BLOCK"
    network_entity_id = oci_core_internet_gateway.this.id
  }
}

# La security list default de una VCN nueva abre 22/tcp al mundo. Como las security lists y los
# NSG son aditivos (pasa el trafico que permita cualquiera de los dos), dejarla como viene
# anularia las reglas del NSG. Se la vacia: todo el filtrado real vive en el NSG.
resource "oci_core_default_security_list" "this" {
  manage_default_resource_id = oci_core_vcn.this.default_security_list_id
  display_name               = "${local.name}-sl-default-vacia"

  egress_security_rules {
    destination      = "0.0.0.0/0"
    destination_type = "CIDR_BLOCK"
    protocol         = "all"
    description      = "Salida a internet (apt, Docker Hub, Steam, Object Storage)"
  }

  # ICMP tipo 3 codigo 4: Path MTU Discovery. Sin esto se cuelgan conexiones TCP grandes.
  ingress_security_rules {
    source      = "0.0.0.0/0"
    source_type = "CIDR_BLOCK"
    protocol    = "1"
    description = "Path MTU Discovery"

    icmp_options {
      type = 3
      code = 4
    }
  }
}

resource "oci_core_subnet" "public" {
  compartment_id             = oci_identity_compartment.this.id
  vcn_id                     = oci_core_vcn.this.id
  cidr_block                 = var.subnet_cidr
  display_name               = "${local.name}-subnet-public"
  dns_label                  = "public"
  route_table_id             = oci_core_route_table.public.id
  prohibit_public_ip_on_vnic = false
}

resource "oci_core_network_security_group" "this" {
  compartment_id = oci_identity_compartment.this.id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name}-nsg"
}

# Juego: UDP 16261-16262 desde cualquier lado (los amigos entran por IP).
resource "oci_core_network_security_group_security_rule" "game_udp" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "17" # UDP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Project Zomboid ${local.game_port_min}-${local.game_port_max}/udp"

  udp_options {
    destination_port_range {
      min = local.game_port_min
      max = local.game_port_max
    }
  }
}

# SSH: solo el admin.
resource "oci_core_network_security_group_security_rule" "ssh" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = var.admin_cidr
  source_type               = "CIDR_BLOCK"
  description               = "SSH solo desde el admin"

  tcp_options {
    destination_port_range {
      min = 22
      max = 22
    }
  }
}

# RCON: solo el admin. Nunca abierto al mundo (da control total del server).
resource "oci_core_network_security_group_security_rule" "rcon" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = var.admin_cidr
  source_type               = "CIDR_BLOCK"
  description               = "RCON solo desde el admin"

  tcp_options {
    destination_port_range {
      min = var.rcon_port
      max = var.rcon_port
    }
  }
}

# Encuesta de reglas: solo existe si survey_port > 0. Es una pagina publica sin login, se
# abre mientras dura la votacion y despues se vuelve survey_port = 0.
resource "oci_core_network_security_group_security_rule" "survey" {
  count = var.survey_port > 0 ? 1 : 0

  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Encuesta de reglas ${var.survey_port}/tcp"

  tcp_options {
    destination_port_range {
      min = var.survey_port
      max = var.survey_port
    }
  }
}

# Panel de moderadores: solo existe si panel_port > 0. La credencial es el token de la URL,
# no la IP de origen: por eso se abre a todo internet, igual que la encuesta.
resource "oci_core_network_security_group_security_rule" "panel" {
  count = var.panel_port > 0 ? 1 : 0

  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "6" # TCP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Panel de moderadores ${var.panel_port}/tcp"

  tcp_options {
    destination_port_range {
      min = var.panel_port
      max = var.panel_port
    }
  }
}

resource "oci_core_network_security_group_security_rule" "icmp_pmtu" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "INGRESS"
  protocol                  = "1" # ICMP
  source                    = "0.0.0.0/0"
  source_type               = "CIDR_BLOCK"
  description               = "Path MTU Discovery"

  icmp_options {
    type = 3
    code = 4
  }
}

resource "oci_core_network_security_group_security_rule" "egress_all" {
  network_security_group_id = oci_core_network_security_group.this.id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Salida sin restricciones"
}

# ---------------------------------------------------------------------------------------------
# Deploy key: par ed25519 generado por Tofu. La privada va a la VM por cloud-init (0600),
# la publica se expone como output para cargarla en GitHub como deploy key de solo lectura.
#
# Solo se genera si el repo se clona por SSH (repo privado). Con un repo_url https:// el
# recurso no existe y no hay ninguna clave privada en la VM.
# ---------------------------------------------------------------------------------------------

resource "tls_private_key" "deploy" {
  count     = local.use_deploy_key ? 1 : 0
  algorithm = "ED25519"
}

# ---------------------------------------------------------------------------------------------
# Object Storage: bucket de backups
# ---------------------------------------------------------------------------------------------

resource "oci_objectstorage_bucket" "backups" {
  compartment_id = oci_identity_compartment.this.id
  namespace      = data.oci_objectstorage_namespace.this.namespace
  name           = var.bucket_name
  access_type    = "NoPublicAccess"
  storage_tier   = "Standard"
  versioning     = "Disabled"

  freeform_tags = {
    project = "zomboid"
  }
}

resource "oci_objectstorage_object_lifecycle_policy" "backups" {
  namespace = data.oci_objectstorage_namespace.this.namespace
  bucket    = oci_objectstorage_bucket.backups.name

  # La policy IAM que autoriza al servicio tiene que existir antes (y propagarse).
  depends_on = [oci_identity_policy.backups]

  rules {
    name        = "borrar-backups-viejos"
    action      = "DELETE"
    is_enabled  = true
    target      = "objects"
    time_amount = var.backup_retention_days
    time_unit   = "DAYS"
  }
}

# ---------------------------------------------------------------------------------------------
# Instance principal: la VM escribe en el bucket sin ninguna credencial en disco.
#
# Los dynamic groups y las policies viven siempre en el compartment raiz (el tenancy).
# ---------------------------------------------------------------------------------------------

resource "oci_identity_dynamic_group" "vm" {
  compartment_id = var.tenancy_ocid
  name           = "${local.name}-vm-dg"
  description    = "La VM del servidor de Zomboid, para autenticar por instance principal"
  matching_rule  = "ALL {instance.id = '${oci_core_instance.this.id}'}"
}

resource "oci_identity_policy" "backups" {
  compartment_id = var.tenancy_ocid
  name           = "${local.name}-backups-policy"
  description    = "Permite a la VM de Zomboid leer y escribir el bucket de backups"

  statements = [
    "Allow dynamic-group ${oci_identity_dynamic_group.vm.name} to read buckets in compartment ${oci_identity_compartment.this.name}",
    "Allow dynamic-group ${oci_identity_dynamic_group.vm.name} to manage objects in compartment ${oci_identity_compartment.this.name} where target.bucket.name = '${oci_objectstorage_bucket.backups.name}'",
    # Sin esto la lifecycle policy del bucket falla con 400-InsufficientServicePermissions:
    # el servicio de Object Storage de la region necesita permiso para borrar objetos viejos.
    "Allow service objectstorage-${var.region} to manage object-family in compartment ${oci_identity_compartment.this.name}",
  ]
}

# ---------------------------------------------------------------------------------------------
# Instancia
# ---------------------------------------------------------------------------------------------

resource "oci_core_instance" "this" {
  compartment_id      = oci_identity_compartment.this.id
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_index].name
  display_name        = "${local.name}-vm"
  shape               = var.shape

  shape_config {
    ocpus         = var.ocpus
    memory_in_gbs = var.memory_gb
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu.images[0].id
    boot_volume_size_in_gbs = var.boot_volume_size_gb
  }

  create_vnic_details {
    subnet_id = oci_core_subnet.public.id
    # La IP publica se maneja aparte con un oci_core_public_ip RESERVED para que sobreviva
    # a los stop/start del patron on-demand de la Fase 3.
    assign_public_ip       = false
    nsg_ids                = [oci_core_network_security_group.this.id]
    hostname_label         = "zomboid"
    skip_source_dest_check = false
  }

  metadata = {
    ssh_authorized_keys = trimspace(var.ssh_public_key)
    user_data = base64encode(templatefile("${path.module}/../../../cloud-init.yaml", {
      vm_user            = var.vm_user
      ssh_public_key     = trimspace(var.ssh_public_key)
      use_deploy_key     = local.use_deploy_key
      deploy_private_key = local.use_deploy_key ? tls_private_key.deploy[0].private_key_openssh : ""
      repo_url           = var.repo_url
      repo_branch        = var.repo_branch
      repo_dir           = var.repo_dir
      timezone           = var.timezone
      backup_hour        = var.backup_hour

      admin_cidr    = var.admin_cidr
      game_port     = var.game_port
      game_udp_port = var.game_udp_port
      rcon_port     = var.rcon_port

      admin_username  = var.admin_username
      admin_password  = var.admin_password
      rcon_password   = var.rcon_password
      server_password = var.server_password
      public_name     = var.public_name
      max_players     = var.max_players
      max_memory      = var.max_memory
      cli_lang        = var.cli_lang
      min_memory      = var.min_memory
      mods_txt        = var.mods_txt

      os_namespace = data.oci_objectstorage_namespace.this.namespace
      region       = var.region
      bucket_name  = var.bucket_name
    }))
  }

  # Al terminar la instancia se borra tambien el boot volume: el estado que importa vive en el
  # bucket de backups y en git, no en el disco.
  preserve_boot_volume = false

  lifecycle {
    # Canonical publica una imagen nueva por mes; sin esto cualquier `apply` recrearia la VM.
    # cloud-init (metadata.user_data) corre solo en el primer boot: un cambio en el template no
    # debe recrear la VM (se perderia el mundo). Para aplicar un cloud-init nuevo a una VM
    # existente se replica el cambio a mano, o se recrea a proposito con `tofu apply -replace`.
    ignore_changes = [source_details[0].source_id, metadata]
  }
}

# ---------------------------------------------------------------------------------------------
# IP publica reservada
#
# Una ephemeral public IP se pierde al hacer stop de la instancia. La RESERVED se queda
# asociada a la private IP de la VNIC y sobrevive stop/start, que es lo que necesita el
# patron on-demand (los amigos guardan IP:16261 como favorito).
# ---------------------------------------------------------------------------------------------

data "oci_core_vnic_attachments" "this" {
  compartment_id = oci_identity_compartment.this.id
  instance_id    = oci_core_instance.this.id
}

data "oci_core_private_ips" "this" {
  vnic_id = data.oci_core_vnic_attachments.this.vnic_attachments[0].vnic_id
}

resource "oci_core_public_ip" "this" {
  compartment_id = oci_identity_compartment.this.id
  display_name   = "${local.name}-ip"
  lifetime       = "RESERVED"
  private_ip_id  = data.oci_core_private_ips.this.private_ips[0].id
}

# ---------------------------------------------------------------------------------------------
# Presupuesto
#
# Los budgets se crean siempre en el compartment raiz y apuntan a un compartment objetivo.
# Aca apuntan al tenancy entero para que ninguna prueba fuera del compartment zomboid quede
# fuera de la alerta.
# ---------------------------------------------------------------------------------------------

resource "oci_budget_budget" "this" {
  count = var.enable_budget ? 1 : 0

  compartment_id = var.tenancy_ocid
  display_name   = "${local.name}-budget"
  description    = "Presupuesto mensual del proyecto Zomboid"
  amount         = var.budget_usd
  reset_period   = "MONTHLY"
  target_type    = "COMPARTMENT"
  targets        = [var.tenancy_ocid]
}

# Avisa temprano: proyeccion de fin de mes por encima del 80% del presupuesto.
resource "oci_budget_alert_rule" "forecast_80" {
  count = var.enable_budget ? 1 : 0

  budget_id      = oci_budget_budget.this[0].id
  display_name   = "${local.name}-forecast-80"
  type           = "FORECAST"
  threshold      = 80
  threshold_type = "PERCENTAGE"
  recipients     = var.alert_email
  message        = "Proyeccion de gasto por encima del 80% del presupuesto de ${var.budget_usd} USD."
}

# Avisa tarde pero seguro: gasto real igual al presupuesto.
resource "oci_budget_alert_rule" "actual_100" {
  count = var.enable_budget ? 1 : 0

  budget_id      = oci_budget_budget.this[0].id
  display_name   = "${local.name}-actual-100"
  type           = "ACTUAL"
  threshold      = 100
  threshold_type = "PERCENTAGE"
  recipients     = var.alert_email
  message        = "Gasto real del mes al 100% del presupuesto de ${var.budget_usd} USD."
}
