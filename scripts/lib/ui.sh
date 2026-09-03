#!/usr/bin/env bash
# Helpers de presentacion compartidos por setup.sh, scripts/doctor.sh, scripts/deploy.sh y
# scripts/destroy-all.sh. No es ejecutable: se hace source.
#
# La idea es que todo lo que ve el usuario tenga la misma forma:
#   OK / AVISO / FALTA + una linea que dice que hacer.

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

ui_say() { echo "$*"; }
ui_ok() { echo "  ${UI_GREEN}OK${UI_RESET}     $*"; }
ui_warn() { echo "  ${UI_YELLOW}AVISO${UI_RESET}  $*"; }
ui_miss() { echo "  ${UI_RED}FALTA${UI_RESET}  $*"; }

# Linea de accion, alineada debajo del OK/AVISO/FALTA.
ui_hint() { echo "         $*"; }

ui_step() { echo "${UI_CYAN}==>${UI_RESET} $*"; }

ui_die() {
  echo "${UI_RED}Error:${UI_RESET} $*" >&2
  exit 1
}

# Pregunta si/no. Devuelve 0 si la respuesta es que si.
#   ui_confirm "Instalo OpenTofu?" s   -> el segundo argumento es el default (s o n)
ui_confirm() {
  local prompt="$1" def="${2:-n}" ans=""
  local opciones="[s/N]"
  [[ "${def}" == "s" ]] && opciones="[S/n]"
  read -r -p "  ${prompt} ${opciones}: " ans || true
  ans="${ans:-${def}}"
  [[ "${ans}" =~ ^[sSyY] ]]
}
