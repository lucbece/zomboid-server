# ---------------------------------------------------------------------------------------------
# Instancia del bot de Discord (encendido on-demand del server). Ver docs/on-demand.md.
#
# El apagado por inactividad y el bot son las dos mitades de lo mismo: la VM del juego se apaga
# sola cuando no queda nadie, y esta maquinita — chica, Always Free y siempre encendida — es la
# que la puede volver a prender desde Discord.
#
# Todo lo de este archivo esta detras de `bot_enabled` (default false): sin eso el modulo se
# comporta exactamente como antes.
#
# Lo que crea:
#   - NSG propio (egress todo; ingress solo SSH desde admin_cidr: el bot no escucha nada)
#   - instancia Always Free con IP publica EFIMERA (a nadie le importa la IP del bot)
#   - dynamic group + policy acotada a INSTANCE_INSPECT e INSTANCE_POWER_ACTIONS sobre la
#     instancia del juego, y sobre ninguna otra
# ---------------------------------------------------------------------------------------------

locals {
  # Los shapes .Flex llevan shape_config (ocpus + memoria); los fijos, como E2.1.Micro, no lo
  # aceptan y el apply falla si se lo pasas igual.
  bot_shape_flexible = endswith(var.bot_shape, ".Flex")

  # A1.Flex es ARM y E2.1.Micro es x86: el catalogo de imagenes se filtra por shape, asi que
  # la arquitectura correcta sale sola.
  bot_venv_dir = "/opt/pz-bot-venv"
}

# ---------------------------------------------------------------------------------------------
# Compartment del bot
#
# El bot va en su propio compartment, y no es cosmetico: OCI no tiene ninguna variable de policy
# que identifique una instancia concreta. Las generales llegan hasta target.compartment.id, y la
# tabla de Core Services agrega solo target.boot-volume.kms-key.id y target.image.id — no existe
# un target.instance.id (una policy que lo use no matchea nunca y la API contesta 404).
#
# La unica forma de que "prender y apagar instancias en el compartment zomboid" signifique
# exactamente "la instancia del juego" es que no haya ninguna otra instancia ahi. Por eso el bot
# vive afuera, en un compartment hermano: asi su permiso no lo alcanza ni a el mismo.
# ---------------------------------------------------------------------------------------------

resource "oci_identity_compartment" "bot" {
  count = var.bot_enabled ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "${var.compartment_name}-bot"
  description    = "Instancia del bot de Discord de Project Zomboid (fuera del compartment del juego)"
  enable_delete  = true
}

data "oci_core_images" "ubuntu_bot" {
  count = var.bot_enabled ? 1 : 0

  compartment_id           = var.tenancy_ocid
  operating_system         = var.operating_system
  operating_system_version = var.operating_system_version
  shape                    = var.bot_shape
  state                    = "AVAILABLE"
  sort_by                  = "TIMECREATED"
  sort_order               = "DESC"
}

# ---------------------------------------------------------------------------------------------
# Red del bot
# ---------------------------------------------------------------------------------------------

resource "oci_core_network_security_group" "bot" {
  count = var.bot_enabled ? 1 : 0

  compartment_id = oci_identity_compartment.this.id
  vcn_id         = oci_core_vcn.this.id
  display_name   = "${local.name}-bot-nsg"
}

resource "oci_core_network_security_group_security_rule" "bot_ssh" {
  count = var.bot_enabled ? 1 : 0

  network_security_group_id = oci_core_network_security_group.bot[0].id
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

resource "oci_core_network_security_group_security_rule" "bot_icmp_pmtu" {
  count = var.bot_enabled ? 1 : 0

  network_security_group_id = oci_core_network_security_group.bot[0].id
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

# El bot solo abre conexiones: Discord (WebSocket + HTTPS), la API de OCI, apt y pip.
resource "oci_core_network_security_group_security_rule" "bot_egress_all" {
  count = var.bot_enabled ? 1 : 0

  network_security_group_id = oci_core_network_security_group.bot[0].id
  direction                 = "EGRESS"
  protocol                  = "all"
  destination               = "0.0.0.0/0"
  destination_type          = "CIDR_BLOCK"
  description               = "Salida sin restricciones"
}

# ---------------------------------------------------------------------------------------------
# Instancia del bot
# ---------------------------------------------------------------------------------------------

resource "oci_core_instance" "bot" {
  count = var.bot_enabled ? 1 : 0

  # Compartment propio (ver arriba). La subnet y el NSG siguen viviendo en el compartment del
  # juego: una VNIC puede usar una subnet de otro compartment sin problema.
  compartment_id      = oci_identity_compartment.bot[0].id
  availability_domain = data.oci_identity_availability_domains.this.availability_domains[var.availability_domain_index].name
  display_name        = "${local.name}-bot"
  shape               = var.bot_shape

  dynamic "shape_config" {
    for_each = local.bot_shape_flexible ? [1] : []
    content {
      ocpus         = var.bot_ocpus
      memory_in_gbs = var.bot_memory_gb
    }
  }

  source_details {
    source_type             = "image"
    source_id               = data.oci_core_images.ubuntu_bot[0].images[0].id
    boot_volume_size_in_gbs = var.bot_boot_volume_size_gb
  }

  create_vnic_details {
    subnet_id = oci_core_subnet.public.id
    # IP efimera: la del bot no la escribe nadie en ningun lado, solo tiene que poder salir.
    assign_public_ip = true
    nsg_ids          = [oci_core_network_security_group.bot[0].id]
    hostname_label   = "bot"
  }

  metadata = {
    ssh_authorized_keys = trimspace(var.ssh_public_key)
    user_data = base64encode(templatefile("${path.module}/../../../cloud-init-bot.yaml", {
      vm_user        = var.vm_user
      ssh_public_key = trimspace(var.ssh_public_key)
      repo_url       = var.bot_repo_url
      repo_branch    = var.repo_branch
      repo_dir       = var.repo_dir
      venv_dir       = local.bot_venv_dir
      timezone       = var.timezone
      admin_cidr     = var.admin_cidr
      region         = var.region

      discord_bot_token    = var.discord_bot_token
      bot_guild_id         = var.bot_guild_id
      bot_admin_user_ids   = var.bot_admin_user_ids
      bot_allowed_role_ids = var.bot_allowed_role_ids

      game_instance_ocid = oci_core_instance.this.id
      game_ip            = oci_core_public_ip.this.ip_address
      game_port          = var.game_port
    }))
  }

  preserve_boot_volume = false

  lifecycle {
    # La imagen nueva de cada mes no tiene que recrear el bot. El user_data SI se mira: aca no
    # hay mundo que perder, y rotar el token de Discord tiene que recrear la instancia.
    ignore_changes = [source_details[0].source_id]

    precondition {
      condition     = !var.bot_enabled || trimspace(var.discord_bot_token) != ""
      error_message = "Con bot_enabled = true hace falta discord_bot_token en terraform.tfvars."
    }
  }
}

# La IP publica efimera se lee de la VNIC (no hay recurso oci_core_public_ip que la represente).
data "oci_core_vnic_attachments" "bot" {
  count = var.bot_enabled ? 1 : 0

  compartment_id = oci_identity_compartment.bot[0].id
  instance_id    = oci_core_instance.bot[0].id
}

data "oci_core_vnic" "bot" {
  count = var.bot_enabled ? 1 : 0

  vnic_id = data.oci_core_vnic_attachments.bot[0].vnic_attachments[0].vnic_id
}

# ---------------------------------------------------------------------------------------------
# Instance principal del bot
#
# El bot no lleva ninguna clave de API: se autentica con el certificado de su propia instancia.
# La policy es deliberadamente diminuta — inspeccionar y prender/apagar UNA instancia, la del
# juego — asi que quien se apodere de la VM del bot no puede crear recursos, ni leer el bucket
# de backups, ni tocar la red.
# ---------------------------------------------------------------------------------------------

resource "oci_identity_dynamic_group" "bot" {
  count = var.bot_enabled ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "${local.name}-bot-dg"
  description    = "La instancia del bot de Discord de Zomboid, para autenticar por instance principal"
  matching_rule  = "ALL {instance.id = '${oci_core_instance.bot[0].id}'}"
}

resource "oci_identity_policy" "bot" {
  count = var.bot_enabled ? 1 : 0

  compartment_id = var.tenancy_ocid
  name           = "${local.name}-bot-policy"
  description    = "Permite al bot de Discord prender y apagar (solo eso) la VM del juego"

  statements = [
    # `use instances` de por si incluye INSTANCE_UPDATE, INSTANCE_ATTACH_VOLUME y varias mas:
    # el `any {request.permission = ...}` la recorta a mirar el estado (GetInstance) y a las
    # acciones de energia (InstanceAction START / SOFTSTOP), que es todo lo que hace el bot.
    #
    # El alcance es el compartment del juego, no un OCID: OCI no tiene una variable de policy
    # que nombre una instancia (ver el comentario del compartment del bot). Como la unica
    # instancia de ese compartment es la del juego —el bot esta en el suyo—, el permiso llega
    # exactamente a una maquina, y ni siquiera a la del propio bot.
    join(" ", [
      "Allow dynamic-group id ${oci_identity_dynamic_group.bot[0].id}",
      "to use instances in compartment id ${oci_identity_compartment.this.id}",
      "where any {request.permission = 'INSTANCE_INSPECT', request.permission = 'INSTANCE_POWER_ACTIONS'}",
    ]),
  ]
}
