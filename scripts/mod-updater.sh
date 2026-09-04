#!/usr/bin/env bash
# Mantiene los mods del server al dia con el Workshop de Steam. Lo corre un timer de systemd
# cada 5 minutos EN LA VM (infra/systemd/zomboid-mod-updater.{service,timer}).
#
#   scripts/mod-updater.sh            # una pasada: compara, avisa y reinicia si toca
#   scripts/mod-updater.sh --check    # solo la tabla de comparacion (no toca nada)
#   DRY_RUN=1 scripts/mod-updater.sh  # dice que haria, sin ejecutar nada
#
# El problema: el server baja los mods del Workshop SOLO al arrancar, y Steam los actualiza
# solos en los clientes. Cuando un autor publica una version nueva con el server prendido, el
# cliente queda adelantado y no puede entrar (ve el server como incompatible). La unica cura
# es reiniciar el server, que vuelve a bajar el mod. Ver docs/mods.md.
#
# Que hace: compara el time_updated que devuelve la API publica de Steam con el timeupdated
# instalado en data/workshop/appworkshop_108600.acf y, si alguno quedo atras, avisa por
# Discord y reinicia (inmediato sin nadie conectado, con cuenta regresiva si hay gente).
# Lo que NO hace nunca: wipe, restore, tocar config/ ni cambiar la lista de mods.
#
# Variables de entorno (las usan las pruebas locales con stubs):
#   MOD_UPDATER_REPO_DIR    raiz del repo        (default: la que deduce del script)
#   MOD_UPDATER_STATE_DIR   estado persistente   (default: /var/tmp/zomboid-mod-updater)
#   MOD_UPDATER_LOG         log propio           (default: /var/log/zomboid/mod-updater.log)
#   MOD_UPDATER_ACF         el .acf del Workshop (default: data/workshop/appworkshop_108600.acf)
#   MOD_UPDATER_API_URL     endpoint de Steam    (default: el publico)
#   ZOMBOID_OPS_LOCK        lock compartido con el watchdog (/var/tmp/zomboid-ops.lock)
#   MOD_UPDATER_OPS_PATTERN patron de pgrep de las operaciones que bloquean una pasada
# curl, python3, flock, pgrep y los scripts del repo se buscan por PATH a proposito, para
# poder sustituirlos por stubs.
set -euo pipefail

REPO_DIR="${MOD_UPDATER_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "${REPO_DIR}"

# El .env se lee antes que la configuracion para que las MOD_UPDATE_* de ahi valgan de verdad.
if [[ -f "${REPO_DIR}/.env" ]]; then
  set -a
  # shellcheck source=/dev/null
  source "${REPO_DIR}/.env"
  set +a
fi

STATE_DIR="${MOD_UPDATER_STATE_DIR:-/var/tmp/zomboid-mod-updater}"
LOG_FILE="${MOD_UPDATER_LOG:-/var/log/zomboid/mod-updater.log}"
OPS_LOCK="${ZOMBOID_OPS_LOCK:-/var/tmp/zomboid-ops.lock}"
MODS_FILE="${REPO_DIR}/config/mods.txt"
ACF="${MOD_UPDATER_ACF:-${REPO_DIR}/data/workshop/appworkshop_108600.acf}"
COMPARAR="${REPO_DIR}/tools/mod-updater/comparar.py"
API_URL="${MOD_UPDATER_API_URL:-https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/}"
DRY_RUN="${DRY_RUN:-0}"

# --- Politica (pisable desde .env) ------------------------------------------------------------
AUTO_RESTART="${MOD_UPDATE_AUTO_RESTART:-1}"        # 0 = solo avisa, no reinicia
DELAY_MIN="${MOD_UPDATE_RESTART_DELAY_MIN:-15}"     # minutos de aviso si hay gente conectada
RECORDATORIOS="${MOD_UPDATE_REMINDERS:-5}"          # minutos restantes en los que se recuerda
VERIFICAR_SEG="${MOD_UPDATE_VERIFY_SECONDS:-900}"   # espera maxima a que baje la version nueva
CURL_TIMEOUT="${MOD_UPDATE_CURL_TIMEOUT:-25}"
# `pgrep -f` mira la linea de comando entera, asi que esto tambien matchea el `ssh vm '... &&
# ./scripts/stop.sh'` que alguien largo desde su maquina. En la VM eso es justo lo que se
# quiere; se deja pisable para poder probarlo sin depender de que corre en el host.
OPS_PATRON="${MOD_UPDATER_OPS_PATTERN:-scripts/(restart|stop|wipe|update|backup)\.sh}"

NOTIF_LOG="${LOG_FILE}"
NOTIF_PREFIJO="mod-updater"
# shellcheck source=scripts/lib/notificar.sh
source "${REPO_DIR}/scripts/lib/notificar.sh"

TMP_DIR=""
limpiar_tmp() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"; return 0; }
trap limpiar_tmp EXIT

# =============================================================================================
# Estado persistente
# =============================================================================================
# pendientes  TSV "id<TAB>time_updated<TAB>titulo" de los mods que estamos esperando actualizar
# deteccion   epoch de la primera deteccion del ciclo
# plazo       epoch en el que vence la cuenta regresiva (vacio = todavia no se anuncio)
# recordatorios  umbrales (en minutos) ya avisados en este ciclo
# fase        vacio = avisando; "esperando" = ya se reinicio y falta confirmar el .acf
# reinicio    epoch del reinicio, para el timeout de la verificacion

leer_estado() { cat "${STATE_DIR}/$1" 2>/dev/null || echo "${2:-}"; }

# Junta las lineas de stdin en una sola separada por ", ". No se usa `paste -sd', '`: ahi cada
# caracter de la lista es un delimitador distinto y tres lineas salen como "a,b c".
juntar() { awk 'NR > 1 { printf ", " } { printf "%s", $0 } END { if (NR) print "" }'; }

escribir_estado() {
  [[ "${DRY_RUN}" == "1" ]] && return 0
  printf '%s\n' "$2" > "${STATE_DIR}/$1"
}

limpiar_ciclo() {
  [[ "${DRY_RUN}" == "1" ]] && return 0
  rm -f "${STATE_DIR}/pendientes" "${STATE_DIR}/deteccion" "${STATE_DIR}/plazo" \
        "${STATE_DIR}/recordatorios" "${STATE_DIR}/fase" "${STATE_DIR}/reinicio"
}

# =============================================================================================
# Acciones (todas respetan DRY_RUN)
# =============================================================================================

avisar() {
  local nivel="$1" titulo="$2" detalle="${3:-}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN: aca notificaria [${nivel}] ${titulo} -- ${detalle}"
    return 0
  fi
  notificar "${nivel}" "${titulo}" "${detalle}"
}

# Mensaje en el chat del juego. Falla blando: un servermsg perdido no justifica abortar.
mensaje_en_juego() {
  local texto="$1"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN: aca mandaria por RCON servermsg \"${texto}\""
    return 0
  fi
  "${REPO_DIR}/scripts/rcon.sh" "servermsg \"${texto}\"" >/dev/null 2>&1 \
    || log "ADVERTENCIA: no se pudo mandar el servermsg"
}

# Jugadores conectados. Imprime el numero, o falla si RCON no responde.
jugadores_conectados() {
  local salida
  salida="$(timeout 20 "${REPO_DIR}/scripts/rcon.sh" players 2>/dev/null)" || return 1
  local n
  n="$(sed -n 's/.*Players connected (\([0-9][0-9]*\)).*/\1/p' <<<"${salida}" | head -n1)"
  [[ "${n}" =~ ^[0-9]+$ ]] || return 1
  echo "${n}"
}

# =============================================================================================
# Deteccion
# =============================================================================================

# Los workshop ids de config/mods.txt, en orden, sin comentarios. Mismo parseo que
# scripts/render-config.sh: el id es el primer campo de cada linea util.
ids_declarados() {
  [[ -f "${MODS_FILE}" ]] || return 0
  sed -e 's/#.*$//' -e 's/^[[:space:]]*//' "${MODS_FILE}" \
    | awk '$1 ~ /^[0-9]+$/ { if (!seen[$1]++) print $1 }'
}

# Consulta la API publica de Steam. Sin API key: GetPublishedFileDetails es anonima.
consultar_api() {
  local destino="$1"
  shift
  local -a ids=("$@")
  local -a datos=(--data-urlencode "itemcount=${#ids[@]}")
  local i
  for i in "${!ids[@]}"; do
    datos+=(--data-urlencode "publishedfileids[${i}]=${ids[i]}")
  done
  curl -fsS -m "${CURL_TIMEOUT}" -X POST "${datos[@]}" "${API_URL}" > "${destino}" 2>>"${LOG_FILE}"
}

# =============================================================================================
# Reinicio
# =============================================================================================

# reiniciar <segundos_de_aviso> <titulos>
reiniciar() {
  local warn="$1" titulos="$2"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "DRY_RUN: aca correria WARN_SECONDS=${warn} scripts/restart.sh (mods: ${titulos})"
    return 0
  fi

  log "reiniciando el server (WARN_SECONDS=${warn}) por: ${titulos}"
  if ! WARN_SECONDS="${warn}" "${REPO_DIR}/scripts/restart.sh" >> "${LOG_FILE}" 2>&1; then
    avisar error "No se pudo reiniciar por la actualizacion de mods" \
      "scripts/restart.sh salio con error. Mods pendientes: ${titulos}"
    limpiar_ciclo
    return 1
  fi

  # El .acf recien queda escrito cuando SteamCMD termina de bajar el mod, bastante despues de
  # que restart.sh vuelve. La verificacion se hace en las pasadas siguientes en vez de dormir
  # aca: una corrida larga se quedaria con el lock compartido y le taparia la boca al watchdog
  # justo durante el arranque, que es cuando mas falta hace.
  escribir_estado fase esperando
  escribir_estado reinicio "$(date +%s)"
  escribir_estado plazo ""
  escribir_estado recordatorios ""
  return 0
}

# =============================================================================================
# main
# =============================================================================================

# Devuelve por stdout las lineas TSV de la comparacion. Falla (1) si no hay datos utilizables.
comparar() {
  local -a ids
  mapfile -t ids < <(ids_declarados)
  if [[ ${#ids[@]} -eq 0 ]]; then
    log "config/mods.txt no declara ningun mod: nada que chequear"
    return 1
  fi

  local api_json="${TMP_DIR}/api.json"
  if ! consultar_api "${api_json}" "${ids[@]}"; then
    log "la API de Steam no respondio (curl fallo): no se hace nada en esta pasada"
    return 1
  fi

  local salida rc=0
  salida="$(python3 "${COMPARAR}" "${ACF}" "${api_json}" "${ids[@]}")" || rc=$?
  if (( rc != 0 )); then
    log "la respuesta de la API no sirve (comparar.py salio con ${rc}): no se hace nada"
    return 1
  fi
  printf '%s\n' "${salida}"
}

modo_check() {
  TMP_DIR="$(mktemp -d)"
  local -a ids
  mapfile -t ids < <(ids_declarados)
  [[ ${#ids[@]} -gt 0 ]] || { echo "mod-updater: config/mods.txt no declara ningun mod" >&2; return 1; }
  local api_json="${TMP_DIR}/api.json"
  consultar_api "${api_json}" "${ids[@]}" \
    || { echo "mod-updater: la API de Steam no respondio" >&2; return 1; }
  python3 "${COMPARAR}" --tabla "${ACF}" "${api_json}" "${ids[@]}"
}

main() {
  if [[ "${1:-}" == "--check" ]]; then
    modo_check
    return $?
  fi

  mkdir -p "${STATE_DIR}" 2>/dev/null || true
  mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
  TMP_DIR="$(mktemp -d)"

  # Lock compartido con el watchdog: los dos pueden reiniciar el server y no pueden hacerlo a
  # la vez. Tambien sirve de "una corrida a la vez" para cada uno.
  # Se crea antes con `:` porque un `exec` con la redireccion fallida mata el shell entero.
  if ! : >> "${OPS_LOCK}" 2>/dev/null; then
    log "ADVERTENCIA: no se puede escribir el lock ${OPS_LOCK}: se saltea esta pasada"
    return 0
  fi
  exec 9>"${OPS_LOCK}"
  if ! flock -n 9; then
    log "hay otra operacion en curso (watchdog o mod-updater), se saltea esta pasada"
    return 0
  fi

  # El lock no cubre lo que se corre a mano por SSH ni lo que lanza el panel de moderadores.
  if pgrep -f "${OPS_PATRON}" >/dev/null 2>&1; then
    log "hay un restart/stop/wipe/update/backup corriendo, se saltea esta pasada"
    return 0
  fi

  local ahora
  ahora="$(date +%s)"

  local filas
  filas="$(comparar)" || return 0

  # Mods que quedaron atras respecto del Workshop.
  local desactualizados titulos_desact
  desactualizados="$(awk -F'\t' '$5 == "desactualizado" { print $1 }' <<<"${filas}")"
  titulos_desact="$(awk -F'\t' '$5 == "desactualizado" { print $2 }' <<<"${filas}" | juntar)"

  # sin-datos / no-instalado se registran pero no disparan nada: un item borrado del Workshop
  # no se arregla reiniciando.
  local raros
  raros="$(awk -F'\t' '$5 == "sin-datos" || $5 == "no-instalado" { print $1" ("$5")" }' \
           <<<"${filas}" | juntar)"
  [[ -n "${raros}" ]] && log "mods sin comparacion util: ${raros}"

  local pendientes fase
  pendientes="$(leer_estado pendientes "")"
  fase="$(leer_estado fase "")"

  # --- Fase 2: ya reiniciamos, falta confirmar que bajo la version nueva --------------------
  if [[ "${fase}" == "esperando" && -z "${pendientes}" ]]; then
    log "estado inconsistente (fase esperando sin pendientes): se cierra el ciclo"
    limpiar_ciclo
    fase=""
  fi

  if [[ "${fase}" == "esperando" ]]; then
    local titulos_pend reinicio
    titulos_pend="$(cut -f3 <<<"${pendientes}" | juntar)"
    reinicio="$(leer_estado reinicio 0)"
    [[ "${reinicio}" =~ ^[0-9]+$ ]] || reinicio=0

    local sigue=0 id
    while IFS=$'\t' read -r id _ _; do
      [[ -n "${id}" ]] || continue
      if grep -qxF -- "${id}" <<<"${desactualizados}"; then sigue=1; fi
    done <<<"${pendientes}"

    if (( sigue == 0 )); then
      avisar info "Server reiniciado con los mods al dia" \
        "Ya se puede entrar. Actualizados: ${titulos_pend}"
      limpiar_ciclo
      return 0
    fi
    if (( ahora - reinicio > VERIFICAR_SEG )); then
      avisar error "No se pudo actualizar el mod" \
        "Despues del reinicio, ${titulos_pend} sigue con la version vieja en el .acf. Hay que mirarlo a mano."
      limpiar_ciclo
      return 0
    fi
    log "esperando a que SteamCMD termine de bajar: ${titulos_pend}"
    return 0
  fi

  # --- Nada desactualizado ------------------------------------------------------------------
  if [[ -z "${desactualizados}" ]]; then
    if [[ -n "${pendientes}" ]]; then
      log "los mods pendientes quedaron al dia sin que reiniciemos nosotros: se cierra el ciclo"
      limpiar_ciclo
    else
      log "todos los mods declarados estan al dia"
    fi
    return 0
  fi

  # --- Hay mods desactualizados -------------------------------------------------------------
  # Se agregan los nuevos al ciclo en curso sin estirar el plazo: los que ya estan jugando
  # tienen una cuenta regresiva y moverla seria peor que reiniciar con dos mods a la vez.
  local nuevos="" id
  while read -r id; do
    [[ -n "${id}" ]] || continue
    if ! grep -qF -- "${id}"$'\t' <<<"${pendientes}"; then nuevos+="${id}"$'\n'; fi
  done <<<"${desactualizados}"

  local pendientes_nuevo
  pendientes_nuevo="$(awk -F'\t' '$5 == "desactualizado" { print $1"\t"$3"\t"$2 }' <<<"${filas}")"
  escribir_estado pendientes "${pendientes_nuevo}"
  [[ -n "${pendientes}" ]] || escribir_estado deteccion "${ahora}"

  local es_nuevo=0
  [[ -n "${nuevos//[$'\n']/}" ]] && es_nuevo=1

  # --- Solo avisar --------------------------------------------------------------------------
  if [[ "${AUTO_RESTART}" != "1" ]]; then
    if (( es_nuevo )); then
      avisar warn "Mod actualizado: ${titulos_desact}" \
        "MOD_UPDATE_AUTO_RESTART=0: no se reinicia solo. Hasta que alguien haga 'make restart' los jugadores con el mod actualizado no van a poder entrar."
    else
      log "sigue desactualizado ${titulos_desact} y MOD_UPDATE_AUTO_RESTART=0: solo se registra"
    fi
    return 0
  fi

  # --- Cuantos hay adentro ------------------------------------------------------------------
  local conectados
  if ! conectados="$(jugadores_conectados)"; then
    log "RCON no responde: se pospone el reinicio por mods (de eso se ocupa el watchdog)"
    return 0
  fi

  if (( conectados == 0 )); then
    avisar warn "Mod actualizado: ${titulos_desact}" \
      "No hay nadie conectado: se reinicia ahora para bajar la version nueva."
    reiniciar 0 "${titulos_desact}" || return 0
    return 0
  fi

  # --- Con gente adentro: cuenta regresiva --------------------------------------------------
  local plazo
  plazo="$(leer_estado plazo "")"

  if [[ ! "${plazo}" =~ ^[0-9]+$ ]]; then
    plazo=$(( ahora + DELAY_MIN * 60 ))
    escribir_estado plazo "${plazo}"
    escribir_estado recordatorios ""
    mensaje_en_juego "El mod ${titulos_desact} se actualizo en Steam. El server se reinicia en ${DELAY_MIN} minutos para que todos puedan volver a entrar."
    avisar warn "Mod actualizado: ${titulos_desact}" \
      "Hay ${conectados} jugador(es) conectado(s): reinicio programado en ${DELAY_MIN} minutos."
    return 0
  fi

  local restante=$(( plazo - ahora ))
  if (( restante <= 0 )); then
    avisar warn "Reiniciando por la actualizacion de ${titulos_desact}" \
      "Se cumplio el plazo con ${conectados} jugador(es) conectado(s). scripts/restart.sh avisa 60 segundos antes de guardar."
    reiniciar 60 "${titulos_desact}" || return 0
    return 0
  fi

  # Recordatorios: por umbral de minutos restantes, cada uno una sola vez por ciclo. El de
  # 1 minuto no esta aca a proposito: lo manda stop.sh con su aviso de 60 segundos, que es
  # exacto, y no depende de que el timer caiga justo en ese minuto.
  if (( es_nuevo )); then
    mensaje_en_juego "Tambien se actualizo un mod (${titulos_desact}). El reinicio sigue programado para dentro de $(( (restante + 59) / 60 )) minutos."
  fi

  local ya umbral
  ya="$(leer_estado recordatorios "")"
  for umbral in ${RECORDATORIOS}; do
    [[ "${umbral}" =~ ^[0-9]+$ ]] || continue
    (( restante <= umbral * 60 )) || continue
    [[ " ${ya} " == *" ${umbral} "* ]] && continue
    # El texto dice los minutos que faltan de verdad, no el umbral: entre el jitter del timer y
    # una pasada salteada por el lock, el umbral de 5 se puede cruzar con 30 segundos restantes.
    mensaje_en_juego "Recordatorio: el server se reinicia en $(( (restante + 59) / 60 )) minuto(s) para actualizar ${titulos_desact}. Ponete a salvo."
    ya="${ya} ${umbral}"
    escribir_estado recordatorios "${ya}"
  done

  log "reinicio pendiente en $(( (restante + 59) / 60 )) minuto(s) por: ${titulos_desact}"
  return 0
}

main "$@"
