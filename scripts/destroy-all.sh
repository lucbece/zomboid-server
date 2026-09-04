#!/usr/bin/env bash
# Borra el servidor de la nube para dejar de pagar.
#
#   make destroy-all          # pide escribir el nombre del server para confirmar
#   scripts/destroy-all.sh --dry-run
#
# Antes de borrar intenta guardar una última copia de la partida en la nube, así podés volver
# a levantar todo más adelante con `make deploy` + `scripts/restore.sh`.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

# shellcheck source=scripts/lib/ui.sh
source "${REPO_DIR}/scripts/lib/ui.sh"
# shellcheck source=scripts/lib/oci-instance.sh
source "${REPO_DIR}/scripts/lib/oci-instance.sh"

TF_DIR="${TF_ENV_DIR}"
TFVARS="${TF_DIR}/terraform.tfvars"
TOFU="${TOFU:-tofu}"
VM_USER="${VM_USER:-pz}"

DRY_RUN=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run | --simular) DRY_RUN=1 ;;
    -h | --help | --ayuda)
      printf '%s\n' "$(t destroy.help)"
      exit 0
      ;;
    *) ui_die "$(t destroy.unknown_option "${arg}")" ;;
  esac
done

export PATH="${HOME}/.local/bin:${PATH}"

tfvar() {
  [[ -f "${TFVARS}" ]] || return 0
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"# ])\"?[[:space:]]*(#.*)?$/\1/p" \
    "${TFVARS}" | head -1
}

public_name="$(tfvar public_name)"
[[ -n "${public_name}" ]] || public_name="$(t destroy.default_name)"

ip="$(tofu_output public_ip "${TF_RE_IP}")"
bucket="$(tofu_output bucket_name "${TF_RE_NOMBRE}")"
namespace="$(tofu_output bucket_namespace "${TF_RE_NOMBRE}")"
region="$(tfvar region)"

if [[ -z "${ip}" && "${DRY_RUN}" -eq 0 ]]; then
  printf '%s\n\n' "$(t destroy.nothing)"
  exit 0
fi

# =============================================================================================
# Confirmación
# =============================================================================================

printf '%s\n\n' "$(t destroy.confirm_block "${ip:-$(t destroy.no_ip)}" "${bucket:-zomboid-backups}")"

if [[ "${DRY_RUN}" -eq 0 ]]; then
  read -r -p "$(t destroy.confirm_prompt "${public_name}")" respuesta || true
  [[ "${respuesta}" == "${public_name}" ]] || ui_die "$(t destroy.mismatch)"
fi

# =============================================================================================
# Backup final
# =============================================================================================

ui_step "$(t destroy.step.backup)"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '%s\n' "$(t destroy.simulated "$(t destroy.backup.simulated "${VM_USER}" "${ip:-IP}")")"
elif [[ -n "${ip}" ]] && ssh -o ConnectTimeout=8 -o BatchMode=yes "${VM_USER}@${ip}" true 2>/dev/null; then
  if ssh -o ConnectTimeout=10 "${VM_USER}@${ip}" \
    'cd /opt/zomboid-server && ./scripts/backup.sh final'; then
    ui_ok "$(t destroy.backup_ok)"
  else
    ui_warn "$(t destroy.backup_fail)"
    if ! ui_confirm "$(t destroy.confirm_anyway)" n; then
      ui_die "$(t destroy.cancelled)"
    fi
  fi
else
  ui_warn "$(t destroy.vm_down)"
  if [[ "${DRY_RUN}" -eq 0 ]] && ! ui_confirm "$(t destroy.confirm_anyway)" n; then
    ui_die "$(t destroy.cancelled)"
  fi
fi

# =============================================================================================
# Destroy
# =============================================================================================

ui_step "$(t destroy.step.destroy)"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '%s\n' "$(t destroy.simulated "${TOFU} -chdir=${TF_DIR} destroy -auto-approve")"
else
  "${TOFU}" -chdir="${TF_DIR}" destroy -input=false -auto-approve
fi

# =============================================================================================
# Qué queda
# =============================================================================================

printf '%s\n\n' "$(t destroy.final \
  "${bucket:-zomboid-backups}" "${bucket:-zomboid-backups}" "${bucket:-zomboid-backups}" \
  "${bucket:-zomboid-backups}" "${namespace:-TU_NAMESPACE}" \
  "${bucket:-zomboid-backups}" "${namespace:-TU_NAMESPACE}" \
  "${region:-sa-saopaulo-1}")"
