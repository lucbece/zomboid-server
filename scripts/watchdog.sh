#!/usr/bin/env bash
# Watchdog determinista del servidor de Project Zomboid. Lo corre un timer de systemd cada
# 2 minutos EN LA VM (infra/systemd/zomboid-watchdog.{service,timer}).
#
#   scripts/watchdog.sh              # una pasada: chequea, actua y notifica
#   DRY_RUN=1 scripts/watchdog.sh    # dice que haria, sin tocar nada
#
# Chequea, en orden: la unit y el contenedor (crash-loop por RestartCount), RCON, patrones
# fatales en el log y presion de disco/memoria. Segun lo que encuentre corre un playbook
# acotado (reiniciar, limpiar disco) y notifica a Discord. Lo que NO hace nunca: wipe,
# restore, borrar nada bajo data/zomboid/Saves o data/zomboid/db, ni tocar config/.
#
# Si el playbook no alcanza, escala: notifica y (solo con CLAUDE_AUTOREPAIR=1 en .env)
# llama a scripts/autorepair.sh. Ver docs/self-healing.md.
#
# Variables de entorno (las usan las pruebas locales con stubs):
#   WATCHDOG_REPO_DIR    raiz del repo             (default: la que deduce del script)
#   WATCHDOG_STATE_DIR   estado persistente        (default: /var/tmp/zomboid-watchdog)
#   WATCHDOG_LOG         log propio                (default: /var/log/zomboid/watchdog.log)
#   ZOMBOID_OPS_LOCK     lock compartido con scripts/mod-updater.sh
#                                                  (default: /var/tmp/zomboid-ops.lock)
# Todos los comandos externos (docker, systemctl, journalctl, df, free, curl, make) se buscan
# por PATH a proposito, para poder sustituirlos por stubs.
set -euo pipefail

REPO_DIR="${WATCHDOG_REPO_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "${REPO_DIR}"

STATE_DIR="${WATCHDOG_STATE_DIR:-/var/tmp/zomboid-watchdog}"
LOG_FILE="${WATCHDOG_LOG:-/var/log/zomboid/watchdog.log}"
# Un solo lock para todo lo que puede reiniciar el server sin que haya nadie mirando: este
# watchdog y scripts/mod-updater.sh. Ademas de excluirse entre si, le sirve a cada uno de
# "una corrida a la vez".
OPS_LOCK="${ZOMBOID_OPS_LOCK:-/var/tmp/zomboid-ops.lock}"
SERVICE="zomboid"
UNIT="zomboid.service"
CONTENEDOR="${WATCHDOG_CONTAINER:-zomboid-server}"
DATA_DIR="${REPO_DIR}/data/zomboid"
DRY_RUN="${DRY_RUN:-0}"

# Codigos de salida: 0 = sano o resuelto, 20 = escalado (lo mira SuccessExitStatus de la unit).
EXIT_OK=0
EXIT_ESCALADO=20

# --- Umbrales (todos pisables desde .env o el entorno) ----------------------------------------
GRACIA_ARRANQUE="${WATCHDOG_GRACE_SECONDS:-300}"      # sin chequear RCON tras arrancar
RCON_FALLOS_MAX="${WATCHDOG_RCON_FAILS:-3}"           # fallos seguidos antes de dar por caido
CRASH_VENTANA="${WATCHDOG_CRASH_WINDOW:-600}"         # ventana de la deteccion de crash-loop
CRASH_DELTA="${WATCHDOG_CRASH_DELTA:-3}"              # reinicios de Docker que la disparan
LOG_VENTANA="${WATCHDOG_LOG_WINDOW:-3m}"              # --since del log para patrones fatales
DISCO_MIN_MB="${WATCHDOG_MIN_DISK_MB:-2048}"          # espacio libre minimo en data/
MAX_REINICIOS_HORA="${WATCHDOG_MAX_RESTARTS_HOUR:-2}" # reinicios automaticos por hora
ESPERA_ARRANQUE="${WATCHDOG_BOOT_WAIT:-300}"          # espera de 'SERVER STARTED' tras make up
RENOTIFICAR="${WATCHDOG_RENOTIFY_SECONDS:-3600}"      # no repetir la misma escalacion antes

PATRONES_FATALES="${REPO_DIR}/tools/watchdog/patrones-fatales.txt"
PATRONES_IGNORAR="${REPO_DIR}/tools/watchdog/patrones-ignorar.txt"

TMP_DIR=""
limpiar() { [[ -n "${TMP_DIR}" && -d "${TMP_DIR}" ]] && rm -rf "${TMP_DIR}"; }
trap limpiar EXIT

# =============================================================================================
# Log y notificaciones
# =============================================================================================
# log() y notificar() salen de la lib compartida; aca solo se dice a que log escribir.

# shellcheck source=scripts/lib/i18n.sh
source "${REPO_DIR}/scripts/lib/i18n.sh"

NOTIF_LOG="${LOG_FILE}"
NOTIF_PREFIJO="watchdog"
# shellcheck source=scripts/lib/notificar.sh
source "${REPO_DIR}/scripts/lib/notificar.sh"

# =============================================================================================
# Estado persistente
# =============================================================================================
# Los archivos de marcas son lineas "epoch<TAB>etiqueta". Sirven para las ventanas de tiempo
# (reinicios en la ultima hora, escalaciones en el dia).

marcar() { printf '%s\t%s\n' "$(date +%s)" "${2:-}" >> "${STATE_DIR}/$1"; }

# contar_marcas <archivo> <ventana_segundos> [etiqueta]
contar_marcas() {
  local archivo="${STATE_DIR}/$1" ventana="$2" etiqueta="${3:-}" corte n=0 ts eti
  corte=$(( $(date +%s) - ventana ))
  [[ -f "${archivo}" ]] || { echo 0; return 0; }
  while IFS=$'\t' read -r ts eti; do
    [[ "${ts}" =~ ^[0-9]+$ ]] || continue
    (( ts < corte )) && continue
    [[ -n "${etiqueta}" && "${eti}" != "${etiqueta}" ]] && continue
    n=$(( n + 1 ))
  done < "${archivo}"
  echo "${n}"
}

# Deja solo las marcas de la ventana, para que el archivo no crezca sin limite.
podar_marcas() {
  local archivo="${STATE_DIR}/$1" ventana="$2" corte
  corte=$(( $(date +%s) - ventana ))
  [[ -f "${archivo}" ]] || return 0
  awk -F'\t' -v corte="${corte}" '$1 ~ /^[0-9]+$/ && $1 >= corte' \
    "${archivo}" > "${archivo}.tmp" && mv "${archivo}.tmp" "${archivo}"
}

leer_estado() { cat "${STATE_DIR}/$1" 2>/dev/null || echo "${2:-}"; }
escribir_estado() { printf '%s\n' "$2" > "${STATE_DIR}/$1"; }

# =============================================================================================
# Chequeos
# =============================================================================================

dc() { docker compose "$@"; }

# Segundos desde que arranco el contenedor. Vacio si no se puede saber.
segundos_desde_arranque() {
  local inicio epoch
  inicio="$(docker inspect --format '{{.State.StartedAt}}' "${CONTENEDOR}" 2>/dev/null || true)"
  [[ -n "${inicio}" ]] || return 1
  epoch="$(date -d "${inicio}" +%s 2>/dev/null || true)"
  [[ "${epoch}" =~ ^[0-9]+$ ]] || return 1
  echo $(( $(date +%s) - epoch ))
}

# 1a. La unit de systemd. Si no esta instalada (PC de desarrollo) no se chequea.
check_unit() {
  local estado
  estado="$(systemctl is-active "${UNIT}" 2>/dev/null || true)"
  case "${estado}" in
    active | activating) return 0 ;;
    "" | unknown) log "$(t watchdog.unit_not_installed "${UNIT}")"; return 0 ;;
    *) DETALLE="systemctl is-active ${UNIT} = ${estado}"; return 1 ;;
  esac
}

# 1b. El contenedor.
check_contenedor() {
  local corriendo
  corriendo="$(docker inspect --format '{{.State.Running}}' "${CONTENEDOR}" 2>/dev/null || true)"
  [[ "${corriendo}" == "true" ]] && return 0
  DETALLE="el contenedor ${CONTENEDOR} no esta corriendo (State.Running=${corriendo:-ausente})"
  return 1
}

# 1c. Crash-loop: el RestartCount de Docker crecio CRASH_DELTA o mas dentro de la ventana.
# Se guarda "epoch<TAB>contador" y se re-basa cuando la ventana vence.
check_crash_loop() {
  local actual previo ts_previo linea ahora
  actual="$(docker inspect --format '{{.RestartCount}}' "${CONTENEDOR}" 2>/dev/null || true)"
  [[ "${actual}" =~ ^[0-9]+$ ]] || return 0
  ahora="$(date +%s)"
  linea="$(leer_estado restartcount "")"
  ts_previo="${linea%%	*}"
  previo="${linea##*	}"

  if [[ ! "${ts_previo}" =~ ^[0-9]+$ || ! "${previo}" =~ ^[0-9]+$ ]] \
     || (( ahora - ts_previo > CRASH_VENTANA )) || (( actual < previo )); then
    printf '%s\t%s\n' "${ahora}" "${actual}" > "${STATE_DIR}/restartcount"
    return 0
  fi

  if (( actual - previo >= CRASH_DELTA )); then
    DETALLE="RestartCount paso de ${previo} a ${actual} en menos de $(( CRASH_VENTANA / 60 )) minutos"
    return 1
  fi
  return 0
}

# Re-basa el contador de crash-loop despues de una accion nuestra (un reinicio nuestro no es
# un crash-loop).
rebasar_crash_loop() {
  local actual
  actual="$(docker inspect --format '{{.RestartCount}}' "${CONTENEDOR}" 2>/dev/null || echo 0)"
  [[ "${actual}" =~ ^[0-9]+$ ]] || actual=0
  printf '%s\t%s\n' "$(date +%s)" "${actual}" > "${STATE_DIR}/restartcount"
}

# 2. RCON. Con gracia despues del arranque y RCON_FALLOS_MAX fallos seguidos.
check_rcon() {
  local desde fallos
  if desde="$(segundos_desde_arranque)" && (( desde < GRACIA_ARRANQUE )); then
    log "$(t watchdog.rcon_grace "${desde}" "${GRACIA_ARRANQUE}")"
    escribir_estado rcon-fallos 0
    return 0
  fi

  if timeout 20 "${REPO_DIR}/scripts/rcon.sh" players >/dev/null 2>&1; then
    escribir_estado rcon-fallos 0
    return 0
  fi

  fallos="$(leer_estado rcon-fallos 0)"
  [[ "${fallos}" =~ ^[0-9]+$ ]] || fallos=0
  fallos=$(( fallos + 1 ))
  escribir_estado rcon-fallos "${fallos}"
  log "$(t watchdog.rcon_fail "${fallos}" "${RCON_FALLOS_MAX}")"
  (( fallos >= RCON_FALLOS_MAX )) || return 0
  DETALLE="RCON no responde a 'players' en ${fallos} chequeos seguidos y el contenedor esta vivo"
  return 1
}

# Los archivos de patrones son regex extendidos, uno por linea, con comentarios '#'. Hay que
# sacarlos antes de pasarselos a grep -f: una linea vacia haria matchear todo.
patrones_limpios() {
  local origen="$1" destino="$2"
  [[ -f "${origen}" ]] || { : > "${destino}"; return 0; }
  sed -e 's/[[:space:]]*#.*$//' -e '/^[[:space:]]*$/d' "${origen}" > "${destino}"
}

# 3. Patrones fatales en el log reciente, descontando el ruido conocido de los mods.
check_log() {
  local fatales ignorar hallazgos
  fatales="${TMP_DIR}/fatales.re"
  ignorar="${TMP_DIR}/ignorar.re"
  patrones_limpios "${PATRONES_FATALES}" "${fatales}"
  patrones_limpios "${PATRONES_IGNORAR}" "${ignorar}"
  [[ -s "${fatales}" ]] || return 0

  local log_reciente="${TMP_DIR}/reciente.log"
  dc logs --no-color --since "${LOG_VENTANA}" "${SERVICE}" > "${log_reciente}" 2>&1 || true
  [[ -s "${log_reciente}" ]] || return 0

  if [[ -s "${ignorar}" ]]; then
    hallazgos="$(grep -E -f "${fatales}" "${log_reciente}" 2>/dev/null \
                 | grep -E -v -f "${ignorar}" 2>/dev/null || true)"
  else
    hallazgos="$(grep -E -f "${fatales}" "${log_reciente}" 2>/dev/null || true)"
  fi
  [[ -n "${hallazgos}" ]] || return 0

  DETALLE="patron fatal en el log de los ultimos ${LOG_VENTANA}:"$'\n'"$(printf '%s\n' "${hallazgos}" | head -n 10)"
  return 1
}

# 4a. El OOM killer del kernel contra la JVM.
check_oom() {
  local hallazgos
  hallazgos="$(journalctl -k --since -10m --no-pager 2>/dev/null \
               | grep -E 'Out of memory: Killed process .*java' || true)"
  [[ -n "${hallazgos}" ]] || return 0
  DETALLE="el kernel mato la JVM por falta de memoria:"$'\n'"$(printf '%s\n' "${hallazgos}" | head -n 5)"
  return 1
}

# 4b. Espacio libre en la particion de data/.
libre_mb() {
  local dir="$1" kb
  [[ -d "${dir}" ]] || dir="${REPO_DIR}"
  kb="$(df -Pk "${dir}" 2>/dev/null | awk 'NR==2 {print $4}')"
  [[ "${kb}" =~ ^[0-9]+$ ]] || return 1
  echo $(( kb / 1024 ))
}

check_disco() {
  local mb
  mb="$(libre_mb "${DATA_DIR}")" || { log "$(t watchdog.df_fail "${DATA_DIR}")"; return 0; }
  (( mb >= DISCO_MIN_MB )) && return 0
  DETALLE="quedan ${mb} MB libres en la particion de data/ (minimo ${DISCO_MIN_MB} MB)"
  return 1
}

# =============================================================================================
# Bundle de diagnostico
# =============================================================================================
# Todo lo que un humano (o autorepair.sh) necesita para entender la caida, en un solo lugar.
# El ini se copia con las claves sensibles tachadas: el bundle puede terminar en un chat.

armar_bundle() {
  local motivo="$1" detalle="$2"
  local dir
  dir="${REPO_DIR}/data/diagnostico/$(date +%Y%m%d-%H%M%S)"
  mkdir -p "${dir}"

  {
    echo "motivo:  ${motivo}"
    echo "fecha:   $(date -Is)"
    echo "host:    $(hostname 2>/dev/null || echo '?')"
    echo
    printf '%s\n' "${detalle}"
  } > "${dir}/motivo.txt"

  dc logs --no-color --tail 800 "${SERVICE}" > "${dir}/log-contenedor.txt" 2>&1 || true
  docker inspect "${CONTENEDOR}" > "${dir}/docker-inspect.json" 2>&1 || true
  df -h > "${dir}/df.txt" 2>&1 || true
  free -m > "${dir}/free.txt" 2>&1 || true
  journalctl -u "${UNIT}" -n 100 --no-pager > "${dir}/journal-zomboid.txt" 2>&1 || true
  journalctl -k --since -30m --no-pager 2>/dev/null \
    | grep -iE 'oom|killed' > "${dir}/journal-oom.txt" 2>&1 || true

  # Mods: la lista declarada y las quejas del log, que es donde aparece el mod que no carga.
  cp "${REPO_DIR}/config/mods.txt" "${dir}/mods.txt" 2>/dev/null || true
  grep -iE 'required mod|not found|ERROR' "${dir}/log-contenedor.txt" 2>/dev/null \
    | tail -n 100 > "${dir}/mods-errores.txt" || true

  # servertest.ini con Password, RCONPassword y DiscordToken tachados.
  if [[ -f "${DATA_DIR}/Server/servertest.ini" ]]; then
    sed -E 's/^([[:space:]]*(Password|RCONPassword|DiscordToken)[[:space:]]*=).*/\1REDACTADO/I' \
      "${DATA_DIR}/Server/servertest.ini" > "${dir}/servertest.ini" 2>/dev/null || true
  fi

  chmod -R go-rwx "${dir}" 2>/dev/null || true
  echo "${dir}"
}

# =============================================================================================
# Playbooks
# =============================================================================================

# Cupo de reinicios automaticos por hora, compartido por todos los playbooks.
hay_cupo_de_reinicio() {
  local hechos
  podar_marcas reinicios 3600
  hechos="$(contar_marcas reinicios 3600)"
  (( hechos < MAX_REINICIOS_HORA ))
}

# Espera a que aparezca 'SERVER STARTED' en el log. 0 si arranco, 1 si se acabo el tiempo.
esperar_arranque() {
  local esperado=0
  while (( esperado < ESPERA_ARRANQUE )); do
    if dc logs --no-color --since 15m "${SERVICE}" 2>&1 | grep -q 'SERVER STARTED'; then
      log "$(t watchdog.started "${esperado}")"
      return 0
    fi
    sleep 10
    esperado=$(( esperado + 10 ))
  done
  return 1
}

# RCON caido con el contenedor vivo: un reinicio limpio y a esperar.
playbook_rcon() {
  local detalle="$1"
  if ! hay_cupo_de_reinicio; then
    escalar "rcon" "${detalle}" "" \
      "ya se hicieron ${MAX_REINICIOS_HORA} reinicios automaticos en la ultima hora"
    return "${EXIT_ESCALADO}"
  fi

  notificar warn "Reiniciando: RCON no responde" "${detalle}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "$(t watchdog.dryrun.restart)"
    return "${EXIT_OK}"
  fi

  marcar reinicios rcon
  if WARN_SECONDS=0 "${REPO_DIR}/scripts/restart.sh" >> "${LOG_FILE}" 2>&1; then
    escribir_estado rcon-fallos 0
    rebasar_crash_loop
    notificar info "Reinicio lanzado" "El server esta arrancando. Se verifica en la proxima pasada."
    return "${EXIT_OK}"
  fi

  local bundle
  bundle="$(armar_bundle "rcon" "${detalle}"$'\n''scripts/restart.sh fallo')"
  escalar "rcon" "${detalle}" "${bundle}" "scripts/restart.sh salio con error"
  return "${EXIT_ESCALADO}"
}

# Crash-loop, patron fatal, OOM o contenedor caido: bundle, un arranque y a verificar.
playbook_critico() {
  local motivo="$1" detalle="$2" bundle

  if ! hay_cupo_de_reinicio; then
    bundle="$(armar_bundle "${motivo}" "${detalle}")"
    escalar "${motivo}" "${detalle}" "${bundle}" \
      "ya se hicieron ${MAX_REINICIOS_HORA} reinicios automaticos en la ultima hora"
    return "${EXIT_ESCALADO}"
  fi

  notificar error "Falla critica: ${motivo}" "${detalle}"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "$(t watchdog.dryrun.critical)"
    return "${EXIT_OK}"
  fi

  # Apagado limpio primero: 'docker compose down' es el ultimo recurso y solo si stop.sh no
  # pudo (el mundo se guarda por RCON, no por SIGKILL).
  log "$(t watchdog.stopping)"
  if ! WARN_SECONDS=0 "${REPO_DIR}/scripts/stop.sh" >> "${LOG_FILE}" 2>&1; then
    log "$(t watchdog.stop_failed)"
    dc down --remove-orphans >> "${LOG_FILE}" 2>&1 || true
  fi

  bundle="$(armar_bundle "${motivo}" "${detalle}")"
  log "$(t watchdog.diagnostic "${bundle}")"

  marcar reinicios "${motivo}"
  log "$(t watchdog.starting)"
  if ! make up >> "${LOG_FILE}" 2>&1; then
    escalar "${motivo}" "${detalle}" "${bundle}" "'make up' salio con error"
    return "${EXIT_ESCALADO}"
  fi

  if esperar_arranque; then
    escribir_estado rcon-fallos 0
    rebasar_crash_loop
    notificar info "Recuperado (${motivo})" \
      "El server volvio a arrancar solo. Diagnostico en ${bundle#"${REPO_DIR}/"}"
    return "${EXIT_OK}"
  fi

  escalar "${motivo}" "${detalle}" "${bundle}" \
    "no aparecio 'SERVER STARTED' en ${ESPERA_ARRANQUE}s despues de 'make up'"
  return "${EXIT_ESCALADO}"
}

# Disco casi lleno: se borra solo lo que se regenera o ya esta en el bucket.
playbook_disco() {
  local detalle="$1" antes despues
  antes="$(libre_mb "${DATA_DIR}")" || antes=0
  notificar warn "Poco espacio en disco" "${detalle}"

  if [[ "${DRY_RUN}" == "1" ]]; then
    log "$(t watchdog.dryrun.disk)"
    return "${EXIT_OK}"
  fi

  # Los tar locales de mas de un dia ya estan en el bucket (los sube backup.sh).
  find "${REPO_DIR}/backups" -maxdepth 1 -type f -name 'zomboid-*.tar.*' -mtime +1 \
    -print -delete >> "${LOG_FILE}" 2>&1 || true
  # Logs del juego: se regeneran solos.
  find "${DATA_DIR}/Logs" -maxdepth 1 -type f -mtime +7 \
    -print -delete >> "${LOG_FILE}" 2>&1 || true
  docker system prune -f >> "${LOG_FILE}" 2>&1 || true

  despues="$(libre_mb "${DATA_DIR}")" || despues=0
  log "$(t watchdog.disk_freed "${antes}" "${despues}")"

  if (( despues >= DISCO_MIN_MB )); then
    notificar info "Disco liberado" "Quedan ${despues} MB libres (habia ${antes} MB)."
    return "${EXIT_OK}"
  fi

  escalar "disco" "${detalle}" "" \
    "despues de limpiar quedan ${despues} MB libres, sigue por debajo de ${DISCO_MIN_MB} MB"
  return "${EXIT_ESCALADO}"
}

# =============================================================================================
# Escalado
# =============================================================================================

# escalar <motivo> <detalle> <bundle_dir> <nota>
escalar() {
  local motivo="$1" detalle="$2" bundle="$3" nota="$4"
  local intentos previa ts_previa motivo_previo ahora
  ahora="$(date +%s)"

  podar_marcas escalaciones 86400
  marcar escalaciones "${motivo}"
  intentos="$(contar_marcas escalaciones 86400 "${motivo}")"

  local cuerpo="${nota}"$'\n\n'"${detalle}"
  [[ -n "${bundle}" ]] && cuerpo="${cuerpo}"$'\n\n'"diagnostico: ${bundle#"${REPO_DIR}/"}"

  # No repetir la misma escalacion en Discord cada 2 minutos: al log va siempre igual.
  previa="$(leer_estado ultima-escalacion "")"
  ts_previa="${previa%%	*}"
  motivo_previo="${previa##*	}"
  if [[ "${motivo_previo}" == "${motivo}" && "${ts_previa}" =~ ^[0-9]+$ ]] \
     && (( ahora - ts_previa < RENOTIFICAR )); then
    log "$(t watchdog.escalated "${motivo}" "${nota}")"
    printf '%s\n' "${cuerpo}" | sed 's/^/    /' >> "${LOG_FILE}" 2>/dev/null || true
  else
    notificar error "Necesita una mano: ${motivo}" "${cuerpo}"
  fi
  printf '%s\t%s\n' "${ahora}" "${motivo}" > "${STATE_DIR}/ultima-escalacion"

  if [[ "${CLAUDE_AUTOREPAIR:-0}" != "1" ]]; then
    log "$(t watchdog.autorepair_off)"
    return 0
  fi
  if [[ ! -x "${REPO_DIR}/scripts/autorepair.sh" ]]; then
    log "$(t watchdog.autorepair_missing)"
    return 0
  fi

  # Sin bundle no hay nada que darle a Claude: se arma uno ahora.
  [[ -n "${bundle}" ]] || bundle="$(armar_bundle "${motivo}" "${detalle}"$'\n'"${nota}")"

  log "$(t watchdog.autorepair_call "${intentos}" "${motivo}")"
  if [[ "${DRY_RUN}" == "1" ]]; then
    log "$(t watchdog.dryrun.autorepair)"
    return 0
  fi
  "${REPO_DIR}/scripts/autorepair.sh" \
    --bundle "${bundle}" --motivo "${motivo}" --intentos "${intentos}" \
    >> "${LOG_FILE}" 2>&1 \
    || log "$(t watchdog.autorepair_rc "$?" "${LOG_FILE}")"
  return 0
}

# =============================================================================================
# main
# =============================================================================================

main() {
  mkdir -p "${STATE_DIR}"
  mkdir -p "$(dirname "${LOG_FILE}")" 2>/dev/null || true
  TMP_DIR="$(mktemp -d)"

  # Una sola operacion a la vez: un playbook puede tardar mas que el intervalo del timer, y
  # mientras corre el mod-updater no tiene que meterse a reiniciar por su cuenta.
  # Se crea antes con `:` porque un `exec` con la redireccion fallida mata el shell entero.
  if ! : >> "${OPS_LOCK}" 2>/dev/null; then
    log "$(t watchdog.lock_unwritable "${OPS_LOCK}")"
    return "${EXIT_OK}"
  fi
  exec 9>"${OPS_LOCK}"
  if ! flock -n 9; then
    log "$(t watchdog.lock_busy)"
    return "${EXIT_OK}"
  fi

  if [[ -f "${REPO_DIR}/.env" ]]; then
    set -a
    # shellcheck source=/dev/null
    source "${REPO_DIR}/.env"
    set +a
  fi

  local problema="" DETALLE=""
  local disco_bajo=0

  # --- Chequeos, en orden ---------------------------------------------------------------
  if ! check_unit; then
    problema="unit"
  elif ! check_contenedor; then
    problema="contenedor"
  elif ! check_crash_loop; then
    problema="crash-loop"
  elif ! check_rcon; then
    problema="rcon"
  elif ! check_log; then
    problema="patron-fatal"
  elif ! check_oom; then
    problema="oom"
  fi
  local detalle="${DETALLE}"

  # El disco se mira siempre: liberarlo es prerrequisito de cualquier otro arreglo, y con el
  # server sano igual conviene limpiar antes de que se llene.
  DETALLE=""
  if ! check_disco; then
    disco_bajo=1
  fi
  local detalle_disco="${DETALLE}"

  local anterior rc="${EXIT_OK}"
  anterior="$(leer_estado ultimo-problema "")"

  if (( disco_bajo )); then
    playbook_disco "${detalle_disco}" || rc=$?
    # Si limpiar alcanzo y no habia otro problema, se re-chequea el disco en la proxima pasada.
    if [[ -z "${problema}" ]]; then
      escribir_estado ultimo-problema "disco"
      return "${rc}"
    fi
  fi

  case "${problema}" in
    "")
      if [[ -n "${anterior}" ]]; then
        notificar info "Todo en orden de nuevo" \
          "El chequeo vuelve a pasar limpio despues de '${anterior}'."
      else
        log "$(t watchdog.healthy)"
      fi
      escribir_estado ultimo-problema ""
      ;;
    rcon)
      playbook_rcon "${detalle}" || rc=$?
      escribir_estado ultimo-problema "rcon"
      ;;
    *)
      playbook_critico "${problema}" "${detalle}" || rc=$?
      escribir_estado ultimo-problema "${problema}"
      ;;
  esac
  return "${rc}"
}

main "$@"
