#!/usr/bin/env bash
# Renderiza infra/cloud-init.yaml (que es un template de OpenTofu) con valores de ejemplo, para
# poder validarlo con `cloud-init schema` sin tocar la nube.
#
#   scripts/render-cloud-init.sh https /tmp/rendered-https.yaml
#   scripts/render-cloud-init.sh ssh   /tmp/rendered-ssh.yaml
#   scripts/render-cloud-init.sh bot   /tmp/rendered-bot.yaml
#
# El primer argumento elige que se renderiza:
#   https -> infra/cloud-init.yaml, repo publico, sin deploy key
#   ssh   -> infra/cloud-init.yaml, repo privado, con deploy key
#   bot   -> infra/cloud-init-bot.yaml (la instancia del bot de Discord; ver docs/on-demand.md)
#
# Lo usa el CI (.github/workflows/ci.yml) y esta documentado en docs/runbook.md §12.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOFU="${TOFU:-tofu}"

mode="${1:-https}"
out="${2:-}"

# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"

die() {
  echo "render-cloud-init: ERROR: $*" >&2
  exit 1
}

case "${mode}" in
  # https renderiza con un mods.txt de ejemplo (ejercita el bloque de write_files); ssh sin mods.
  https) use_deploy_key=false; repo_url="https://github.com/lucbece/zomboid-server.git"; mods_txt="$(cat "${REPO_DIR}/config/mods.example.txt")" ;;
  ssh) use_deploy_key=true; repo_url="git@github.com:lucbece/zomboid-server.git"; mods_txt="" ;;
  bot) use_deploy_key=false; repo_url="https://github.com/lucbece/zomboid-server.git"; mods_txt="" ;;
  *) die "$(t cloudinit.unknown_mode "${mode}")" ;;
esac

[[ -n "${out}" ]] || die "$(t cloudinit.no_out "$0")"
command -v "${TOFU}" >/dev/null 2>&1 || die "$(t cloudinit.no_tofu)"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# El cloud-init del bot tiene otro juego de variables (no hay deploy key ni config del juego),
# asi que se renderiza con su propio main.tf y el script termina aca.
if [[ "${mode}" == "bot" ]]; then
  cat >"${work}/main.tf" <<'TFBOT'
variable "template" { type = string }

output "rendered" {
  value = templatefile(var.template, {
    vm_user        = "pz"
    ssh_public_key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJEMPLOEJEMPLOEJEMPLOEJEMPLOEJEMPLO usuario@pc"
    repo_url       = "https://github.com/lucbece/zomboid-server.git"
    repo_branch    = "main"
    repo_dir       = "/opt/zomboid-server"
    venv_dir       = "/opt/pz-bot-venv"
    timezone       = "America/Argentina/Buenos_Aires"
    admin_cidr     = "203.0.113.10/32"
    region         = "sa-saopaulo-1"

    discord_bot_token    = "EJEMPLO.DE.TOKEN"
    bot_guild_id         = "000000000000000000"
    bot_admin_user_ids   = ""
    bot_allowed_role_ids = ""

    game_instance_ocid = "ocid1.instance.oc1..aaaaaaaaCAMBIAME"
    game_ip            = "203.0.113.10"
    game_port          = 16261
  })
}
TFBOT

  "${TOFU}" -chdir="${work}" init -input=false -backend=false >/dev/null
  "${TOFU}" -chdir="${work}" apply -input=false -auto-approve \
    -var "template=${REPO_DIR}/infra/cloud-init-bot.yaml" >/dev/null
  "${TOFU}" -chdir="${work}" output -raw rendered >"${out}"

  printf '%s\n' "$(t cloudinit.done "bot" "${out}")"
  exit 0
fi

# Clave de descarte generada al vuelo: el template solo la indenta, no la valida, y asi no
# queda ninguna clave privada escrita en el repo (gitleaks la marcaria, con razon).
ssh-keygen -q -t ed25519 -N '' -C 'render-cloud-init' -f "${work}/deploy_key"
fake_key="$(cat "${work}/deploy_key")"

cat >"${work}/main.tf" <<'TF'
variable "template" { type = string }
variable "use_deploy_key" { type = bool }
variable "deploy_private_key" { type = string }
variable "repo_url" { type = string }
variable "mods_txt" { type = string }

output "rendered" {
  value = templatefile(var.template, {
    vm_user            = "pz"
    ssh_public_key     = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIEJEMPLOEJEMPLOEJEMPLOEJEMPLOEJEMPLO usuario@pc"
    use_deploy_key     = var.use_deploy_key
    deploy_private_key = var.deploy_private_key
    repo_url           = var.repo_url
    repo_branch        = "main"
    repo_dir           = "/opt/zomboid-server"
    timezone           = "America/Argentina/Buenos_Aires"
    backup_hour        = 6

    admin_cidr    = "203.0.113.10/32"
    game_port     = 16261
    game_udp_port = 16262
    rcon_port     = 27015

    admin_username  = "admin"
    admin_password  = "ejemplo-de-password-1234"
    rcon_password   = "ejemplo-de-password-5678"
    server_password = "ejemplo-de-password-9012"
    public_name     = "Mi server de Zomboid"
    max_players     = 16
    max_memory      = "12g"
    cli_lang        = "es"
    min_memory      = "2048m"
    mods_txt        = var.mods_txt

    os_namespace = "grejemplo"
    compartment_ocid = "ocid1.compartment.oc1..aaaaaaaaCAMBIAME"
    region       = "sa-saopaulo-1"
    bucket_name  = "zomboid-backups"
  })
}
TF

"${TOFU}" -chdir="${work}" init -input=false -backend=false >/dev/null
"${TOFU}" -chdir="${work}" apply -input=false -auto-approve \
  -var "template=${REPO_DIR}/infra/cloud-init.yaml" \
  -var "use_deploy_key=${use_deploy_key}" \
  -var "deploy_private_key=${fake_key}" \
  -var "repo_url=${repo_url}" \
  -var "mods_txt=${mods_txt}" >/dev/null
"${TOFU}" -chdir="${work}" output -raw rendered >"${out}"

printf '%s\n' "$(t cloudinit.done "${mode}" "${out}")"
