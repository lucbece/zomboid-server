#!/usr/bin/env bash
# Idioma del CLI y catalogo de mensajes. No es ejecutable: se hace source.
#
# Lo hace source scripts/lib/ui.sh, asi que todo lo que ya usaba la UI compartida lo recibe
# gratis. Los scripts que no usan ui.sh (watchdog, mod-updater, backup, ...) lo hacen source
# directamente.
#
# El idioma sale, en este orden:
#   1. la variable de entorno ZS_LANG
#   2. la linea ZS_LANG= del .env del repo (se lee con sed, no con `source`: este archivo se
#      hace source antes de que el script decida si carga el .env entero)
#   3. el prefijo de LC_ALL / LC_MESSAGES / LANG  (es* -> es)
#   4. en
#
# Solo valen "es" y "en"; cualquier otra cosa cae a "en".
#
# Uso:
#   t <clave> [args de printf...]   imprime MSG[clave] formateado con printf (sin salto final)
#
# Si la clave no existe imprime la clave y una linea de aviso por stderr: una traduccion que
# falta se nota, pero nunca rompe un script.
#
# Requiere bash 4 (array asociativo). setup.sh ya rechaza el bash 3 de macOS.

[[ -n "${ZS_I18N_LOADED:-}" ]] && return 0

ZS_I18N_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZS_I18N_DIR="${ZS_I18N_LIB_DIR}/i18n"
ZS_I18N_ENV_FILE="${ZS_I18N_ENV_FILE:-$(cd "${ZS_I18N_LIB_DIR}/../.." && pwd)/.env}"

declare -A MSG

# Lee ZS_LANG del .env sin hacerle source: el .env tiene contrasenas y lo carga cada script
# cuando le toca, no esta lib.
i18n_lang_del_env() {
  [[ -f "${ZS_I18N_ENV_FILE}" ]] || return 0
  sed -n -E 's/^[[:space:]]*ZS_LANG[[:space:]]*=[[:space:]]*"?([A-Za-z_]+)"?[[:space:]]*$/\1/p' \
    "${ZS_I18N_ENV_FILE}" 2>/dev/null | head -1
}

i18n_detectar() {
  local candidato=""
  if [[ -n "${ZS_LANG+definida}" ]]; then
    candidato="${ZS_LANG}"
  else
    candidato="$(i18n_lang_del_env)"
  fi
  if [[ -z "${candidato}" ]]; then
    candidato="${LC_ALL:-${LC_MESSAGES:-${LANG:-}}}"
    candidato="${candidato%%.*}"
    candidato="${candidato%%_*}"
  fi
  case "${candidato}" in
    es | es*) echo "es" ;;
    *) echo "en" ;;
  esac
}

# i18n_load <es|en>: carga el catalogo. Siempre se carga primero el ingles, asi una clave que
# le falte al castellano sale en ingles en vez de salir como la clave pelada.
i18n_load() {
  local lang="${1:-en}"
  [[ "${lang}" == "es" || "${lang}" == "en" ]] || lang="en"
  # shellcheck source=scripts/lib/i18n/en.sh
  source "${ZS_I18N_DIR}/en.sh"
  if [[ "${lang}" == "es" ]]; then
    # shellcheck source=scripts/lib/i18n/es.sh
    source "${ZS_I18N_DIR}/es.sh"
  fi
  ZS_LANG="${lang}"
}

# t <clave> [args...] -> imprime el mensaje formateado, sin salto de linea final.
t() {
  local clave="${1:-}" fmt
  shift || true
  if [[ -z "${MSG[${clave}]+definida}" ]]; then
    printf 'i18n: missing key %s\n' "${clave}" >&2
    printf '%s' "${clave}"
    return 0
  fi
  fmt="${MSG[${clave}]}"
  # shellcheck disable=SC2059  # el formato sale del catalogo, no de la entrada del usuario
  printf -- "${fmt}" "$@"
}

i18n_load "$(i18n_detectar)"
ZS_I18N_LOADED=1
