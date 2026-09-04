#!/usr/bin/env bash
# Renderiza la config versionada de config/ hacia el bind mount data/zomboid/Server/.
#
#   config/servertest.ini.tpl + .env + config/mods.txt -> data/zomboid/Server/servertest.ini
#   config/*.lua                                       -> data/zomboid/Server/
#
# config/mods.txt es opcional y no se versiona: sin el, la partida es vanilla (sin mods).
# Falla si falta cualquier variable que el template use, y tambien si el ini ya renderizado
# tenia mods y ahora no habria ninguno (ALLOW_VANILLA=1 lo permite): sacar todos los mods de
# un mundo existente rompe los objetos y celdas que dependen de ellos.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

ENV_FILE="${REPO_DIR}/.env"
TPL="${REPO_DIR}/config/servertest.ini.tpl"
MODS_FILE="${REPO_DIR}/config/mods.txt"
SERVER_DIR="${REPO_DIR}/data/zomboid/Server"
OUT_INI="${SERVER_DIR}/servertest.ini"

# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"

die() {
  echo "render-config: ERROR: $*" >&2
  exit 1
}

command -v envsubst >/dev/null 2>&1 || die "$(t render.need_envsubst)"
[[ -f "${ENV_FILE}" ]] || die "$(t render.no_env "${ENV_FILE}")"
[[ -f "${TPL}" ]] || die "$(t render.no_tpl "${TPL}")"

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a
# Variables agregadas despues de que existieran .env en produccion: con default, para que un
# .env viejo siga rendereando. Las nuevas de verdad siguen siendo obligatorias.
export UPNP="${UPNP:-false}"

# --- Mods: config/mods.txt -> MODS / WORKSHOP_ITEMS ---------------------------------------
# MOD_ID_PREFIX permite probar el prefijo "\" por Mod ID que pedia B42 temprano.
MOD_ID_PREFIX="${MOD_ID_PREFIX:-}"
mod_ids=()
workshop_ids=()
trim() { sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"$1"; }
if [[ -f "${MODS_FILE}" ]]; then
  lineno=0
  # shellcheck disable=SC2094  # el archivo solo se lee; los die() de adentro no lo escriben
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    line="$(trim "${line%%#*}")"
    [[ -z "${line}" ]] && continue
    # Formato: <workshop_id>  <mod_id>[; <mod_id>...]  # comentario
    # Los Mod IDs pueden tener espacios ("Jump Jump"), por eso el campo va hasta el final de la
    # linea y los sub-mods se separan con ';'.
    workshop_id="${line%%[[:space:]]*}"
    ids_field="$(trim "${line#"${workshop_id}"}")"
    [[ "${workshop_id}" =~ ^[0-9]+$ ]] || die "$(t render.bad_workshop_id "${MODS_FILE}" "${lineno}" "${workshop_id}")"
    [[ -n "${ids_field}" ]] || die "$(t render.missing_modid "${MODS_FILE}" "${lineno}" "${workshop_id}")"
    IFS=';' read -r -a ids <<<"${ids_field}"
    for id in "${ids[@]}"; do
      id="$(trim "${id}")"
      [[ -n "${id}" ]] || continue
      mod_ids+=("${MOD_ID_PREFIX}${id}")
    done
    # Un workshop item puede traer varios mods: no repetirlo en WorkshopItems=.
    if [[ " ${workshop_ids[*]-} " != *" ${workshop_id} "* ]]; then
      workshop_ids+=("${workshop_id}")
    fi
  done <"${MODS_FILE}"
else
  printf '%s\n' "$(t render.no_mods)"
fi
MODS="$(IFS=';'; echo "${mod_ids[*]-}")"
WORKSHOP_ITEMS="$(IFS=';'; echo "${workshop_ids[*]-}")"
export MODS WORKSHOP_ITEMS

# Freno: si el mundo ya corria con mods y este render los sacaria todos, lo mas probable es
# que config/mods.txt se haya perdido (no se versiona), no que alguien quiera un mundo vanilla.
if [[ -z "${MODS}" && -f "${OUT_INI}" && "${ALLOW_VANILLA:-0}" != "1" ]]; then
  mods_previos="$(sed -n 's/^Mods=//p' "${OUT_INI}" | head -n1)"
  if [[ -n "${mods_previos}" ]]; then
    printf '%s\n' "$(t render.vanilla_block "${mods_previos}")" >&2
    exit 1
  fi
fi

# --- Validacion: toda variable ${VAR} del template tiene que estar definida ----------------
# shellcheck disable=SC2016  # el patron busca literalmente ${VAR} en el template
mapfile -t tpl_vars < <(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${TPL}" | tr -d '${}' | sort -u)
[[ ${#tpl_vars[@]} -gt 0 ]] || die "$(t render.no_tpl_vars "${TPL}")"

# Estas pueden estar definidas pero vacias (placeholders opcionales).
MAY_BE_EMPTY=" DISCORD_TOKEN DISCORD_CHAT_CHANNEL DISCORD_LOG_CHANNEL DISCORD_COMMAND_CHANNEL MODS WORKSHOP_ITEMS "

missing=()
empty=()
for var in "${tpl_vars[@]}"; do
  if [[ -z "${!var+definida}" ]]; then
    missing+=("${var}")
  elif [[ -z "${!var}" && "${MAY_BE_EMPTY}" != *" ${var} "* ]]; then
    empty+=("${var}")
  fi
done
[[ ${#missing[@]} -eq 0 ]] || die "$(t render.missing_vars "${ENV_FILE}" "${missing[*]}")"
[[ ${#empty[@]} -eq 0 ]] || die "$(t render.empty_vars "${ENV_FILE}" "${empty[*]}")"

# --- Render ------------------------------------------------------------------------------
mkdir -p "${SERVER_DIR}"

subst_list=""
for var in "${tpl_vars[@]}"; do
  subst_list+="\${${var}}"
done

envsubst "${subst_list}" < "${TPL}" > "${OUT_INI}.tmp"
# shellcheck disable=SC2016  # se busca el literal ${ que dejaria un placeholder sin resolver
if grep -q '\${' "${OUT_INI}.tmp"; then
  rm -f "${OUT_INI}.tmp"
  die "$(t render.placeholders)"
fi
mv "${OUT_INI}.tmp" "${OUT_INI}"
chmod 640 "${OUT_INI}"

# config/servertest_SandboxVars.lua es propio de cada partida y no se versiona: si falta, se
# usa el ejemplo versionado (valores vanilla del juego).
SANDBOX="${REPO_DIR}/config/servertest_SandboxVars.lua"
if [[ ! -f "${SANDBOX}" ]]; then
  printf '%s\n' "$(t render.no_sandbox)"
  install -m 644 "${REPO_DIR}/config/servertest_SandboxVars.example.lua" "${SERVER_DIR}/servertest_SandboxVars.lua"
fi
for lua in "${REPO_DIR}"/config/*.lua; do
  [[ -e "${lua}" ]] || continue
  case "${lua}" in *.example.lua) continue ;; esac
  install -m 644 "${lua}" "${SERVER_DIR}/$(basename "${lua}")"
done

echo "render-config: ${OUT_INI}"
echo "render-config:   Mods=${MODS}"
echo "render-config:   WorkshopItems=${WORKSHOP_ITEMS}"
printf '%s\n' "$(t render.lua_copied "${SERVER_DIR}")"
