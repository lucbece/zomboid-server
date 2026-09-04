#!/usr/bin/env bash
# Helpers de presentacion compartidos por setup.sh, scripts/doctor.sh, scripts/deploy.sh y
# scripts/destroy-all.sh. No es ejecutable: se hace source.
#
# La idea es que todo lo que ve el usuario tenga la misma forma:
#   OK / AVISO / FALTA + una linea que dice que hacer.
#
# Hace source de scripts/lib/i18n.sh, asi que todo lo que ya usaba esta lib recibe `t` y el
# idioma resuelto sin tocar nada mas.

# shellcheck source=scripts/lib/i18n.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/i18n.sh"

# Colores solo si la salida es una terminal (respeta NO_COLOR: https://no-color.org).
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  UI_RESET=$'\033[0m'
  UI_BOLD=$'\033[1m'
  UI_GREEN=$'\033[32m'
  UI_YELLOW=$'\033[33m'
  UI_RED=$'\033[31m'
  UI_CYAN=$'\033[36m'
else
  UI_RESET=''
  UI_BOLD=''
  UI_GREEN=''
  UI_YELLOW=''
  UI_RED=''
  UI_CYAN=''
fi

# Titulo de seccion, con una linea de guiones del mismo largo.
ui_title() {
  local text="$*"
  echo
  echo "${UI_BOLD}${text}${UI_RESET}"
  printf '%s\n' "${text//?/-}"
}

# Las etiquetas del catalogo vienen rellenadas a 7 caracteres para que la linea de accion de
# ui_hint (9 espacios) siga alineada en los dos idiomas.
ui_say() { echo "$*"; }
ui_ok() { echo "  ${UI_GREEN}$(t ui.label.ok)${UI_RESET} $*"; }
ui_warn() { echo "  ${UI_YELLOW}$(t ui.label.warn)${UI_RESET} $*"; }
ui_miss() { echo "  ${UI_RED}$(t ui.label.miss)${UI_RESET} $*"; }

# Linea de accion, alineada debajo del OK/AVISO/FALTA (2 + 7 de etiqueta + 1 = 10 columnas).
ui_hint() { echo "          $*"; }

ui_step() { echo "${UI_CYAN}==>${UI_RESET} $*"; }

ui_die() {
  echo "${UI_RED}$(t ui.error)${UI_RESET} $*" >&2
  exit 1
}

# Pregunta si/no. Devuelve 0 si la respuesta es que si.
#   ui_confirm "$(t setup.tofu.confirm)" s   -> el segundo argumento es el default (s o n)
ui_confirm() {
  local prompt="$1" def="${2:-n}" ans=""
  local opciones
  if [[ "${def}" == "s" ]]; then
    opciones="$(t ui.confirm.yes)"
  else
    opciones="$(t ui.confirm.no)"
  fi
  read -r -p "  ${prompt} ${opciones}: " ans || true
  ans="${ans:-${def}}"
  [[ "${ans}" =~ ^[sSyY] ]]
}
