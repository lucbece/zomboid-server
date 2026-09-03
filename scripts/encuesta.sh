#!/usr/bin/env bash
# Encuesta web de reglas de la partida: la levanta en la VM, trae los votos y los cuenta.
#
#   scripts/encuesta.sh up          # sincroniza, instala la unit y arranca la encuesta
#   scripts/encuesta.sh down        # para y deshabilita la encuesta
#   scripts/encuesta.sh estado      # como esta la unit y cuantos votaron
#   scripts/encuesta.sh resultados  # baja votos.jsonl y muestra el conteo
#   scripts/encuesta.sh aplicar     # el conteo + escribe los cambios en config/
#
# Variables: VM_IP (si no, sale del output de OpenTofu), VM_USER (pz), VM_DIR
# (/opt/zomboid-server), ENCUESTA_PUERTO (8080).
#
# Ojo: el puerto tiene que estar abierto en el NSG. Eso es survey_port en terraform.tfvars
# (0 = cerrado) + tofu apply. Ver docs/runbook.md, seccion "Encuesta de reglas".
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

# shellcheck source=scripts/lib/ui.sh
source "${REPO_DIR}/scripts/lib/ui.sh"
# shellcheck source=scripts/lib/oci-instance.sh
source "${REPO_DIR}/scripts/lib/oci-instance.sh"

VM_USER="${VM_USER:-pz}"
VM_DIR="${VM_DIR:-/opt/zomboid-server}"
PUERTO="${ENCUESTA_PUERTO:-8080}"
UNIT="zomboid-encuesta.service"
IP=""  # la completa main() antes de llamar a cualquier cmd_* que use la VM
DATOS_VM="${VM_DIR}/data/encuesta"
DATOS_LOCAL="${REPO_DIR}/data/encuesta"
VOTOS_LOCAL="${DATOS_LOCAL}/votos.jsonl"

uso() {
  cat <<MSG
uso: scripts/encuesta.sh <comando>

  up          sincroniza tools/ e infra/systemd/, instala la unit y arranca la encuesta
  down        para y deshabilita la encuesta (los votos quedan en la VM)
  estado      estado de la unit y cuantas personas votaron
  resultados  baja votos.jsonl y muestra el conteo (no toca config/)
  aplicar     el conteo + escribe los cambios en config/ y muestra el diff
MSG
}

# IP de la VM: la del entorno o la del output de OpenTofu.
resolver_ip() {
  if [[ -n "${VM_IP:-}" ]]; then
    echo "${VM_IP}"
    return 0
  fi
  local ip
  ip="$(tofu_output public_ip "${TF_RE_IP}")" || true
  if [[ -z "${ip}" ]]; then
    ui_die "no hay IP de la VM. Probar: scripts/encuesta.sh $1 con VM_IP=203.0.113.10"
  fi
  echo "${ip}"
}

remoto() {
  ssh -o ConnectTimeout=10 "${VM_USER}@${IP}" "$@"
}

cmd_up() {
  ui_step "Sincronizando el repo a la VM (${VM_USER}@${IP})"
  make sync "VM_IP=${IP}" >/dev/null

  ui_step "Instalando y arrancando la encuesta"
  remoto "sudo install -m 644 -o root -g root \
            '${VM_DIR}/infra/systemd/${UNIT}' '/etc/systemd/system/${UNIT}' &&
          sudo install -d -m 755 -o ${VM_USER} -g ${VM_USER} '${DATOS_VM}' &&
          sudo systemctl daemon-reload &&
          sudo systemctl enable --now '${UNIT}' &&
          sudo ufw allow '${PUERTO}/tcp' comment 'Encuesta de reglas' >/dev/null"

  ui_ok "Encuesta arriba en http://${IP}:${PUERTO}"
  ui_hint "Pasales ese link a los amigos. Cierra sola cuando corras: make encuesta-down"
  ui_hint "Si no abre desde afuera, falta el puerto en el NSG:"
  ui_hint "  survey_port = ${PUERTO} en infra/terraform/envs/prod/terraform.tfvars + make infra-apply"
}

cmd_down() {
  ui_step "Parando la encuesta"
  remoto "sudo systemctl disable --now '${UNIT}';
          sudo ufw delete allow '${PUERTO}/tcp' >/dev/null 2>&1 || true"
  ui_ok "Encuesta apagada. Los votos siguen en ${DATOS_VM}/votos.jsonl"
  ui_hint "Para contarlos: make encuesta-resultados"
}

cmd_estado() {
  ui_step "Estado de la encuesta en ${IP}"
  remoto "systemctl status --no-pager --lines=3 '${UNIT}' || true"
  echo
  remoto "curl -fsS 'http://127.0.0.1:${PUERTO}/salud' 2>/dev/null ||
          echo '{\"ok\": false, \"nota\": \"la encuesta no responde en el puerto ${PUERTO}\"}'"
  echo
  remoto "wc -l < '${DATOS_VM}/votos.jsonl' 2>/dev/null |
          xargs -I{} echo 'lineas en votos.jsonl: {}' ||
          echo 'todavia no hay votos.jsonl'"
}

cmd_resultados() {
  mkdir -p "${DATOS_LOCAL}"
  ui_step "Bajando los votos"
  if ! scp -o ConnectTimeout=10 "${VM_USER}@${IP}:${DATOS_VM}/votos.jsonl" "${VOTOS_LOCAL}"; then
    ui_die "no se pudo bajar ${DATOS_VM}/votos.jsonl (todavia no voto nadie?)"
  fi
  ui_ok "Votos en ${VOTOS_LOCAL}"
  echo
  python3 "${REPO_DIR}/tools/encuesta/tally.py" --votos "${VOTOS_LOCAL}"
}

cmd_aplicar() {
  [[ -f "${VOTOS_LOCAL}" ]] || ui_die "no hay ${VOTOS_LOCAL}. Correr primero: make encuesta-resultados"
  python3 "${REPO_DIR}/tools/encuesta/tally.py" --votos "${VOTOS_LOCAL}" --aplicar
}

main() {
  local comando="${1:-}"
  case "${comando}" in
    up | down | estado | resultados) ;;
    aplicar)
      # Es el unico que no necesita la VM: trabaja sobre el votos.jsonl ya bajado.
      cmd_aplicar
      return 0
      ;;
    "" | -h | --help | help)
      uso
      return 0
      ;;
    *)
      uso >&2
      ui_die "comando desconocido: ${comando}"
      ;;
  esac

  IP="$(resolver_ip "${comando}")"
  "cmd_${comando}"
}

main "$@"
