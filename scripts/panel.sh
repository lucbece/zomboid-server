#!/usr/bin/env bash
# Panel de moderadores: lo levanta en la VM y administra los tokens (uno por moderador).
#
#   scripts/panel.sh up                 # sincroniza, instala la unit, abre el puerto y arranca
#   scripts/panel.sh down               # para el panel y cierra el puerto en ufw
#   scripts/panel.sh estado             # estado de la unit + /salud + moderadores cargados
#   scripts/panel.sh token add Fulano   # crea el token e imprime la URL entera
#   scripts/panel.sh token list         # nombres, alta y estado (no imprime los tokens)
#   scripts/panel.sh token revoke Fulano
#   scripts/panel.sh log [N]            # ultimas N acciones (default 20)
#
# Variables: VM_IP (si no, sale del output de OpenTofu), VM_USER (pz), VM_DIR
# (/opt/zomboid-server), PANEL_PUERTO (8081).
#
# Ojo: el puerto tiene que estar abierto en el NSG. Eso es panel_port en terraform.tfvars
# (0 = cerrado) + tofu apply. Ver docs/panel.md.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

# shellcheck source=scripts/lib/ui.sh
source "${REPO_DIR}/scripts/lib/ui.sh"
# shellcheck source=scripts/lib/oci-instance.sh
source "${REPO_DIR}/scripts/lib/oci-instance.sh"

VM_USER="${VM_USER:-pz}"
VM_DIR="${VM_DIR:-/opt/zomboid-server}"
PUERTO="${PANEL_PUERTO:-8081}"
UNIT="zomboid-panel.service"
IP=""  # la completa main() antes de llamar a cualquier cmd_* que use la VM
DATOS_VM="${VM_DIR}/data/panel"

uso() {
  printf '%s\n' "$(t panel.usage)"
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
    ui_die "$(t panel.no_ip "$1")"
  fi
  echo "${ip}"
}

remoto() {
  ssh -o ConnectTimeout=10 "${VM_USER}@${IP}" "$@"
}

# Un solo lugar donde se arma la llamada a tools/panel/tokens.py en la VM. Recibe el resto de
# la linea ya citada para el shell remoto (ver el printf '%q' de los que la llaman).
tokens_py() {
  remoto "python3 '${VM_DIR}/tools/panel/tokens.py' --datos '${DATOS_VM}' ${1}"
}

cmd_up() {
  ui_step "$(t panel.step.sync "${VM_USER}@${IP}")"
  make sync "VM_IP=${IP}" >/dev/null

  ui_step "$(t panel.step.install)"
  remoto "sudo install -m 644 -o root -g root \
            '${VM_DIR}/infra/systemd/${UNIT}' '/etc/systemd/system/${UNIT}' &&
          sudo install -d -m 700 -o ${VM_USER} -g ${VM_USER} '${DATOS_VM}' &&
          sudo install -d -m 755 -o ${VM_USER} -g ${VM_USER} /var/log/zomboid &&
          sudo systemctl daemon-reload &&
          sudo systemctl enable '${UNIT}' >/dev/null 2>&1 &&
          sudo systemctl restart '${UNIT}' &&
          sudo ufw allow '${PUERTO}/tcp' comment 'Panel de moderadores' >/dev/null"

  ui_ok "$(t panel.up "${IP}" "${PUERTO}")"
  ui_hint "$(t panel.up_hint1)"
  ui_hint "$(t panel.up_hint2)"
  ui_hint "$(t panel.up_hint3)"
  ui_hint "$(t panel.up_hint4 "${PUERTO}")"
}

cmd_down() {
  ui_step "$(t panel.step.down)"
  remoto "sudo systemctl disable --now '${UNIT}';
          sudo ufw delete allow '${PUERTO}/tcp' >/dev/null 2>&1 || true"
  ui_ok "$(t panel.down_ok "${DATOS_VM}")"
  ui_hint "$(t panel.down_hint)"
}

cmd_estado() {
  local nota
  nota="$(t panel.status.nores "${PUERTO}")"
  ui_step "$(t panel.step.status "${IP}")"
  remoto "systemctl status --no-pager --lines=3 '${UNIT}' || true"
  echo
  remoto "curl -fsS 'http://127.0.0.1:${PUERTO}/salud' 2>/dev/null ||
          echo '{\"ok\": false, \"nota\": \"${nota}\"}'"
  echo
  echo
  tokens_py list || true
}

cmd_token() {
  local sub="${1:-}"
  shift || true
  case "${sub}" in
    add)
      local nombre="${1:-}"
      [[ -n "${nombre}" ]] || ui_die "$(t panel.token.usage_add)"
      local token
      token="$(tokens_py "add $(printf '%q' "${nombre}")")" || ui_die "$(t panel.token.create_fail)"
      [[ -n "${token}" ]] || ui_die "$(t panel.token.empty)"
      ui_ok "$(t panel.token.created "${nombre}")"
      echo
      echo "  http://${IP}:${PUERTO}/m/${token}"
      echo
      ui_hint "$(t panel.token.hint1)"
      ui_hint "$(t panel.token.hint2 "${nombre}")"
      ;;
    list)
      tokens_py list
      ;;
    revoke)
      local nombre="${1:-}"
      [[ -n "${nombre}" ]] || ui_die "$(t panel.token.usage_revoke)"
      tokens_py "revoke $(printf '%q' "${nombre}")"
      ui_ok "$(t panel.token.revoked)"
      ;;
    *)
      uso >&2
      ui_die "$(t panel.token.usage)"
      ;;
  esac
}

cmd_log() {
  local n="${1:-20}"
  local sin_acciones
  sin_acciones="$(t panel.log.none)"
  ui_step "$(t panel.log.title "${n}")"
  remoto "tail -n '${n}' '${DATOS_VM}/acciones.jsonl' 2>/dev/null ||
          echo '${sin_acciones}'"
}

main() {
  local comando="${1:-}"
  shift || true
  case "${comando}" in
    up | down | estado | token | log) ;;
    "" | -h | --help | help)
      uso
      return 0
      ;;
    *)
      uso >&2
      ui_die "$(t panel.unknown_cmd "${comando}")"
      ;;
  esac

  IP="$(resolver_ip "${comando}")"
  "cmd_${comando}" "$@"
}

main "$@"
