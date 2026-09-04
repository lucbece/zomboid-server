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
  cat <<MSG
uso: scripts/panel.sh <comando>

  up                      sincroniza el repo, instala la unit, abre el puerto y arranca el panel
  down                    para el panel y cierra el puerto en ufw (los tokens quedan en la VM)
  estado                  estado de la unit, /salud y moderadores cargados
  token add <nombre>      crea un token y imprime la URL completa para ese moderador
  token list              lista los moderadores (no imprime los tokens enteros)
  token revoke <nombre>   desactiva el token de un moderador
  log [N]                 ultimas N acciones registradas (default 20)
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
    ui_die "no hay IP de la VM. Probar: scripts/panel.sh $1 con VM_IP=203.0.113.10"
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
  ui_step "Sincronizando el repo a la VM (${VM_USER}@${IP})"
  make sync "VM_IP=${IP}" >/dev/null

  ui_step "Instalando y arrancando el panel"
  remoto "sudo install -m 644 -o root -g root \
            '${VM_DIR}/infra/systemd/${UNIT}' '/etc/systemd/system/${UNIT}' &&
          sudo install -d -m 700 -o ${VM_USER} -g ${VM_USER} '${DATOS_VM}' &&
          sudo install -d -m 755 -o ${VM_USER} -g ${VM_USER} /var/log/zomboid &&
          sudo systemctl daemon-reload &&
          sudo systemctl enable '${UNIT}' >/dev/null 2>&1 &&
          sudo systemctl restart '${UNIT}' &&
          sudo ufw allow '${PUERTO}/tcp' comment 'Panel de moderadores' >/dev/null"

  ui_ok "Panel arriba en http://${IP}:${PUERTO}"
  ui_hint "Sin token no se ve nada: cada moderador necesita el suyo."
  ui_hint "  make panel-token NAME=Fulano   -> imprime la URL para pasarle por privado"
  ui_hint "Si no abre desde afuera, falta el puerto en el NSG:"
  ui_hint "  panel_port = ${PUERTO} en infra/terraform/envs/prod/terraform.tfvars + make infra-apply"
}

cmd_down() {
  ui_step "Parando el panel"
  remoto "sudo systemctl disable --now '${UNIT}';
          sudo ufw delete allow '${PUERTO}/tcp' >/dev/null 2>&1 || true"
  ui_ok "Panel apagado. Los tokens siguen en ${DATOS_VM}/moderadores.json"
  ui_hint "El puerto sigue abierto en el NSG hasta que pongas panel_port = 0 y apliques."
}

cmd_estado() {
  ui_step "Estado del panel en ${IP}"
  remoto "systemctl status --no-pager --lines=3 '${UNIT}' || true"
  echo
  remoto "curl -fsS 'http://127.0.0.1:${PUERTO}/salud' 2>/dev/null ||
          echo '{\"ok\": false, \"nota\": \"el panel no responde en el puerto ${PUERTO}\"}'"
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
      [[ -n "${nombre}" ]] || ui_die "uso: scripts/panel.sh token add <nombre>"
      local token
      token="$(tokens_py "add $(printf '%q' "${nombre}")")" || ui_die "no se pudo crear el token"
      [[ -n "${token}" ]] || ui_die "el token salio vacio"
      ui_ok "Token creado para ${nombre}"
      echo
      echo "  http://${IP}:${PUERTO}/m/${token}"
      echo
      ui_hint "Pasaselo por mensaje privado. Ese link ES la credencial: quien lo tenga puede"
      ui_hint "reiniciar el server. Para darlo de baja: make panel-revoke NAME=${nombre}"
      ;;
    list)
      tokens_py list
      ;;
    revoke)
      local nombre="${1:-}"
      [[ -n "${nombre}" ]] || ui_die "uso: scripts/panel.sh token revoke <nombre>"
      tokens_py "revoke $(printf '%q' "${nombre}")"
      ui_ok "Token revocado. El panel lo toma solo, sin reiniciar el servicio."
      ;;
    *)
      uso >&2
      ui_die "uso: scripts/panel.sh token add|list|revoke"
      ;;
  esac
}

cmd_log() {
  local n="${1:-20}"
  ui_step "Ultimas ${n} acciones del panel"
  remoto "tail -n '${n}' '${DATOS_VM}/acciones.jsonl' 2>/dev/null ||
          echo '(todavia no hay acciones registradas)'"
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
      ui_die "comando desconocido: ${comando}"
      ;;
  esac

  IP="$(resolver_ip "${comando}")"
  "cmd_${comando}" "$@"
}

main "$@"
