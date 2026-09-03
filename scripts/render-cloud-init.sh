#!/usr/bin/env bash
# Renderiza infra/cloud-init.yaml (que es un template de OpenTofu) con valores de ejemplo, para
# poder validarlo con `cloud-init schema` sin tocar la nube.
#
#   scripts/render-cloud-init.sh https /tmp/rendered-https.yaml
#   scripts/render-cloud-init.sh ssh   /tmp/rendered-ssh.yaml
#
# El primer argumento elige el modo de clonado del repo:
#   https -> repo publico, sin deploy key
#   ssh   -> repo privado, con deploy key
#
# Lo usa el CI (.github/workflows/ci.yml) y esta documentado en docs/runbook.md §12.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TOFU="${TOFU:-tofu}"

mode="${1:-https}"
out="${2:-}"

die() {
  echo "render-cloud-init: ERROR: $*" >&2
  exit 1
}

case "${mode}" in
  https) use_deploy_key=false; repo_url="https://github.com/lucbece/zomboid-server.git" ;;
  ssh) use_deploy_key=true; repo_url="git@github.com:lucbece/zomboid-server.git" ;;
  *) die "modo desconocido '${mode}': usar 'https' o 'ssh'" ;;
esac

[[ -n "${out}" ]] || die "falta el archivo de salida. Uso: $0 {https|ssh} salida.yaml"
command -v "${TOFU}" >/dev/null 2>&1 || die "falta 'tofu' en el PATH"

work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

# Clave de descarte generada al vuelo: el template solo la indenta, no la valida, y asi no
# queda ninguna clave privada escrita en el repo (gitleaks la marcaria, con razon).
ssh-keygen -q -t ed25519 -N '' -C 'render-cloud-init' -f "${work}/deploy_key"
fake_key="$(cat "${work}/deploy_key")"

cat >"${work}/main.tf" <<'TF'
variable "template" { type = string }
variable "use_deploy_key" { type = bool }
variable "deploy_private_key" { type = string }
variable "repo_url" { type = string }

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
    min_memory      = "2048m"

    os_namespace = "grejemplo"
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
  -var "repo_url=${repo_url}" >/dev/null
"${TOFU}" -chdir="${work}" output -raw rendered >"${out}"

echo "render-cloud-init: modo '${mode}' -> ${out}"
