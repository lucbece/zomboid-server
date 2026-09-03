#!/usr/bin/env bash
# Renderiza la config versionada de config/ hacia el bind mount data/zomboid/Server/.
#
#   config/servertest.ini.tpl + .env + config/mods.txt -> data/zomboid/Server/servertest.ini
#   config/*.lua                                       -> data/zomboid/Server/
#
# Falla si falta cualquier variable que el template use.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

ENV_FILE="${REPO_DIR}/.env"
TPL="${REPO_DIR}/config/servertest.ini.tpl"
MODS_FILE="${REPO_DIR}/config/mods.txt"
SERVER_DIR="${REPO_DIR}/data/zomboid/Server"
OUT_INI="${SERVER_DIR}/servertest.ini"

die() {
  echo "render-config: ERROR: $*" >&2
  exit 1
}

command -v envsubst >/dev/null 2>&1 || die "falta envsubst (paquete gettext-base)"
[[ -f "${ENV_FILE}" ]] || die "no existe ${ENV_FILE}. Copiar .env.example a .env y completarlo."
[[ -f "${TPL}" ]] || die "no existe ${TPL}"

set -a
# shellcheck source=/dev/null
source "${ENV_FILE}"
set +a

# --- Mods: config/mods.txt -> MODS / WORKSHOP_ITEMS ---------------------------------------
# MOD_ID_PREFIX permite probar el prefijo "\" por Mod ID que pedia B42 temprano.
MOD_ID_PREFIX="${MOD_ID_PREFIX:-}"
mod_ids=()
workshop_ids=()
trim() { sed -E 's/^[[:space:]]+|[[:space:]]+$//g' <<<"$1"; }
if [[ -f "${MODS_FILE}" ]]; then
  lineno=0
  while IFS= read -r line || [[ -n "${line}" ]]; do
    lineno=$((lineno + 1))
    line="$(trim "${line%%#*}")"
    [[ -z "${line}" ]] && continue
    # Formato: <workshop_id>  <mod_id>[; <mod_id>...]  # comentario
    # Los Mod IDs pueden tener espacios ("Jump Jump"), por eso el campo va hasta el final de la
    # linea y los sub-mods se separan con ';'.
    workshop_id="${line%%[[:space:]]*}"
    ids_field="$(trim "${line#"${workshop_id}"}")"
    [[ "${workshop_id}" =~ ^[0-9]+$ ]] || die "${MODS_FILE}:${lineno}: workshop id invalido '${workshop_id}'"
    [[ -n "${ids_field}" ]] || die "${MODS_FILE}:${lineno}: falta el mod_id para el workshop ${workshop_id}"
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
fi
MODS="$(IFS=';'; echo "${mod_ids[*]-}")"
WORKSHOP_ITEMS="$(IFS=';'; echo "${workshop_ids[*]-}")"
export MODS WORKSHOP_ITEMS

# --- Validacion: toda variable ${VAR} del template tiene que estar definida ----------------
# shellcheck disable=SC2016  # el patron busca literalmente ${VAR} en el template
mapfile -t tpl_vars < <(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*\}' "${TPL}" | tr -d '${}' | sort -u)
[[ ${#tpl_vars[@]} -gt 0 ]] || die "el template no tiene ninguna variable, revisar ${TPL}"

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
[[ ${#missing[@]} -eq 0 ]] || die "faltan variables en ${ENV_FILE}: ${missing[*]}"
[[ ${#empty[@]} -eq 0 ]] || die "variables vacias en ${ENV_FILE}: ${empty[*]}"

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
  die "quedaron placeholders sin resolver en el ini renderizado"
fi
mv "${OUT_INI}.tmp" "${OUT_INI}"
chmod 640 "${OUT_INI}"

for lua in "${REPO_DIR}"/config/*.lua; do
  [[ -e "${lua}" ]] || continue
  install -m 644 "${lua}" "${SERVER_DIR}/$(basename "${lua}")"
done

echo "render-config: ${OUT_INI}"
echo "render-config:   Mods=${MODS}"
echo "render-config:   WorkshopItems=${WORKSHOP_ITEMS}"
echo "render-config: lua copiados a ${SERVER_DIR}/"
