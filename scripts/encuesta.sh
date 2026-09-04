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
  printf '%s\n' "$(t survey.usage)"
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
    ui_die "$(t survey.no_ip "$1")"
  fi
  echo "${ip}"
}

remoto() {
  ssh -o ConnectTimeout=10 "${VM_USER}@${IP}" "$@"
}

cmd_up() {
  ui_step "$(t survey.step.sync "${VM_USER}@${IP}")"
  make sync "VM_IP=${IP}" >/dev/null

  ui_step "$(t survey.step.install)"
  remoto "sudo install -m 644 -o root -g root \
            '${VM_DIR}/infra/systemd/${UNIT}' '/etc/systemd/system/${UNIT}' &&
          sudo install -d -m 755 -o ${VM_USER} -g ${VM_USER} '${DATOS_VM}' &&
          sudo systemctl daemon-reload &&
          sudo systemctl enable '${UNIT}' >/dev/null 2>&1 &&
          sudo systemctl restart '${UNIT}' &&
          sudo ufw allow '${PUERTO}/tcp' comment 'Encuesta de reglas' >/dev/null"

  ui_ok "$(t survey.up "${IP}" "${PUERTO}")"
  ui_hint "$(t survey.up_hint1)"
  ui_hint "$(t survey.up_hint2)"
  ui_hint "$(t survey.up_hint3 "${PUERTO}")"
}

cmd_down() {
  ui_step "$(t survey.step.down)"
  remoto "sudo systemctl disable --now '${UNIT}';
          sudo ufw delete allow '${PUERTO}/tcp' >/dev/null 2>&1 || true"
  ui_ok "$(t survey.down_ok "${DATOS_VM}")"
  ui_hint "$(t survey.down_hint)"
}

cmd_estado() {
  local nota etiqueta sin_votos
  nota="$(t survey.status.nores "${PUERTO}")"
  etiqueta="$(t survey.status.votes)"
  sin_votos="$(t survey.status.novotes)"
  ui_step "$(t survey.step.status "${IP}")"
  remoto "systemctl status --no-pager --lines=3 '${UNIT}' || true"
  echo
  remoto "curl -fsS 'http://127.0.0.1:${PUERTO}/salud' 2>/dev/null ||
          echo '{\"ok\": false, \"nota\": \"${nota}\"}'"
  echo
  remoto "wc -l < '${DATOS_VM}/votos.jsonl' 2>/dev/null |
          xargs -I{} echo '${etiqueta} {}' ||
          echo '${sin_votos}'"
}

cmd_resultados() {
  mkdir -p "${DATOS_LOCAL}"
  ui_step "$(t survey.step.results)"
  if ! scp -o ConnectTimeout=10 "${VM_USER}@${IP}:${DATOS_VM}/votos.jsonl" "${VOTOS_LOCAL}"; then
    ui_die "$(t survey.results_fail "${DATOS_VM}")"
  fi
  ui_ok "$(t survey.results_ok "${VOTOS_LOCAL}")"
  echo
  python3 "${REPO_DIR}/tools/encuesta/tally.py" --votos "${VOTOS_LOCAL}"
}

cmd_aplicar() {
  [[ -f "${VOTOS_LOCAL}" ]] || ui_die "$(t survey.no_votes "${VOTOS_LOCAL}")"
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
      ui_die "$(t survey.unknown_cmd "${comando}")"
      ;;
  esac

  IP="$(resolver_ip "${comando}")"
  "cmd_${comando}"
}

main "$@"
