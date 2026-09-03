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
      sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) ui_die "opción desconocida: ${arg}" ;;
  esac
done

export PATH="${HOME}/.local/bin:${PATH}"

tfvar() {
  [[ -f "${TFVARS}" ]] || return 0
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"# ])\"?[[:space:]]*(#.*)?$/\1/p" \
    "${TFVARS}" | head -1
}

public_name="$(tfvar public_name)"
[[ -n "${public_name}" ]] || public_name="Mi server de Zomboid"

ip="$(tofu_output public_ip "${TF_RE_IP}")"
bucket="$(tofu_output bucket_name "${TF_RE_NOMBRE}")"
namespace="$(tofu_output bucket_namespace "${TF_RE_NOMBRE}")"
region="$(tfvar region)"

if [[ -z "${ip}" && "${DRY_RUN}" -eq 0 ]]; then
  cat <<'NADA'

  No encuentro ningún servidor creado desde esta computadora (no hay estado de OpenTofu).

  Si ya lo borraste, no hay nada que hacer y no se te está cobrando nada por la máquina.
  Si lo creaste desde OTRA computadora, tenés que borrarlo desde esa, o a mano en la consola
  de Oracle Cloud: menú -> Compute -> Instances -> los tres puntos -> Terminate.

NADA
  exit 0
fi

# =============================================================================================
# Confirmación
# =============================================================================================

cat <<CONFIRMA

  ============================================================
   BORRAR TODO
  ============================================================

  Se borra, sin vuelta atrás:

    - la máquina del servidor (${ip:-sin IP})
    - su disco, con la partida que tenga adentro
    - la red y la IP fija (tus amigos van a tener que cargar la IP nueva si volvés a crearlo)

  NO se borra:

    - las copias de seguridad guardadas en la nube (bucket "${bucket:-zomboid-backups}")
      Se siguen cobrando, pero son centavos: unos 0,03 USD por GB por mes.

  Antes de borrar voy a intentar guardar una última copia de la partida.

CONFIRMA

if [[ "${DRY_RUN}" -eq 0 ]]; then
  read -r -p "  Escribí el nombre del server (${public_name}) para confirmar: " respuesta || true
  [[ "${respuesta}" == "${public_name}" ]] || ui_die "no coincide: no se borró nada"
fi

# =============================================================================================
# Backup final
# =============================================================================================

ui_step "Guardando una última copia de la partida"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "         (simulado) ssh ${VM_USER}@${ip:-IP} 'cd /opt/zomboid-server && ./scripts/backup.sh final'"
elif [[ -n "${ip}" ]] && ssh -o ConnectTimeout=8 -o BatchMode=yes "${VM_USER}@${ip}" true 2>/dev/null; then
  if ssh -o ConnectTimeout=10 "${VM_USER}@${ip}" \
    'cd /opt/zomboid-server && ./scripts/backup.sh final'; then
    ui_ok "copia guardada en la nube con la etiqueta 'final'"
  else
    ui_warn "la copia final falló"
    if ! ui_confirm "¿Borro igual?" n; then
      ui_die "cancelado: no se borró nada"
    fi
  fi
else
  ui_warn "la máquina no responde (puede estar apagada): no se pudo hacer la copia final"
  if [[ "${DRY_RUN}" -eq 0 ]] && ! ui_confirm "¿Borro igual?" n; then
    ui_die "cancelado: no se borró nada"
  fi
fi

# =============================================================================================
# Destroy
# =============================================================================================

ui_step "Borrando el servidor (tarda 2-5 minutos)"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "         (simulado) ${TOFU} -chdir=${TF_DIR} destroy -auto-approve"
else
  "${TOFU}" -chdir="${TF_DIR}" destroy -input=false -auto-approve
fi

# =============================================================================================
# Qué queda
# =============================================================================================

cat <<FINAL

  ============================================================
   Listo: el servidor ya no existe y dejaste de pagarlo
  ============================================================

  Lo único que puede seguir generando un costo mínimo son las copias de seguridad guardadas
  en Oracle Cloud, en el bucket "${bucket:-zomboid-backups}". Son unos centavos por mes y te
  sirven si algún día querés volver a levantar la partida:

     make deploy
     ssh USUARIO@IP_NUEVA 'cd /opt/zomboid-server && ./scripts/restore.sh oci:${bucket:-zomboid-backups}/ARCHIVO.tar.zst'

  Si querés borrar también las copias y no dejar nada:

     Desde la consola: menú -> Storage -> Buckets -> ${bucket:-zomboid-backups} -> borrar los
     objetos y después el bucket. Después, menú -> Identity -> Compartments -> zomboid ->
     Delete (solo se puede si ya está vacío).

  Con el programa 'oci' instalado, lo mismo desde la terminal:

     oci os object bulk-delete --bucket-name ${bucket:-zomboid-backups} --namespace ${namespace:-TU_NAMESPACE}
     oci os bucket delete --bucket-name ${bucket:-zomboid-backups} --namespace ${namespace:-TU_NAMESPACE}

  Verificá que no quede nada facturándose en: Billing & Cost Management -> Cost Analysis
  (región ${region:-sa-saopaulo-1}).

FINAL
