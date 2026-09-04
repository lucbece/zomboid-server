#!/usr/bin/env bash
# Crea (o actualiza) el servidor en la nube, de punta a punta.
#
#   make deploy              # lo normal: muestra qué va a hacer y pide confirmación una vez
#   make deploy YES=1        # sin confirmación
#   scripts/deploy.sh --dry-run   # solo muestra los pasos, no toca nada ni gasta plata
#
# Los pasos son:
#   1. revisión previa (scripts/doctor.sh)
#   2. tofu init                       (baja los plugins de Oracle Cloud)
#   3. si el repo es privado: crear la llave de solo lectura y cargarla en GitHub
#   4. tofu apply                      (acá se crea la máquina: empieza a cobrarse)
#   5. esperar a que la máquina acepte conexiones           (hasta 10 minutos)
#   6. esperar a que el juego termine de instalarse y arranque (hasta 30 minutos)
#   7. mostrar lo que hay que pasarle a los amigos
#
# Es idempotente: si ya está todo desplegado, no cambia nada y vuelve a mostrar los datos.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

# shellcheck source=scripts/lib/ui.sh
source "${REPO_DIR}/scripts/lib/ui.sh"
# shellcheck source=scripts/lib/oci-instance.sh
source "${REPO_DIR}/scripts/lib/oci-instance.sh"

TF_DIR="${TF_ENV_DIR}"
TFVARS="${TF_DIR}/terraform.tfvars"
TOFU="${TOFU:-tofu}"
VM_USER="${VM_USER:-pz}"
GAME_PORT="${GAME_PORT:-16261}"

# Cuánto se espera cada cosa. cloud-init hace apt upgrade y baja una imagen de Docker de
# 10.4 GB: la primera vez son 15-30 minutos reales.
ESPERA_SSH_SEG="${ESPERA_SSH_SEG:-600}"    # 10 minutos
ESPERA_JUEGO_SEG="${ESPERA_JUEGO_SEG:-1800}" # 30 minutos

SIN_PREGUNTAR=0
DRY_RUN=0

for arg in "$@"; do
  case "${arg}" in
    -y | --yes | --si) SIN_PREGUNTAR=1 ;;
    --dry-run | --simular) DRY_RUN=1 ;;
    -h | --help | --ayuda)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) ui_die "opción desconocida: ${arg}" ;;
  esac
done

export PATH="${HOME}/.local/bin:${PATH}"

SSH_OPTS=(-o ConnectTimeout=5 -o BatchMode=yes -o StrictHostKeyChecking=accept-new
  -o UserKnownHostsFile="${HOME}/.ssh/known_hosts")

tfvar() {
  [[ -f "${TFVARS}" ]] || return 0
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"# ])\"?[[:space:]]*(#.*)?$/\1/p" \
    "${TFVARS}" | head -1
}

# correr <descripcion> -- <comando...>: en --dry-run solo lo imprime.
correr() {
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "         (simulado) $*"
    return 0
  fi
  "$@"
}

# =============================================================================================
# 1. Revisión previa
# =============================================================================================

ui_step "Paso 1 de 7: revisando que esté todo en orden"

if "${REPO_DIR}/scripts/doctor.sh" --quiet; then
  ui_ok "todo en orden"
elif [[ "${DRY_RUN}" -eq 1 ]]; then
  ui_warn "falta algo, pero como es una simulación sigo igual para mostrarte los pasos"
else
  cat <<'CORTE'

  No puedo seguir hasta que se resuelva lo de arriba.
  En la mayoría de los casos alcanza con correr:  ./setup.sh

CORTE
  exit 1
fi

[[ -f "${TFVARS}" || "${DRY_RUN}" -eq 1 ]] || ui_die "falta ${TFVARS}. Corré ./setup.sh"

repo_url="$(tfvar repo_url)"
server_password="$(tfvar server_password)"
public_name="$(tfvar public_name)"
[[ -n "${repo_url}" ]] || repo_url="https://github.com/lucbece/zomboid-server.git"

# =============================================================================================
# 2. Preparar OpenTofu
# =============================================================================================

ui_step "Paso 2 de 7: preparando las herramientas (se bajan una sola vez)"
correr "${TOFU}" -chdir="${TF_DIR}" init -input=false

# =============================================================================================
# 3. Llave de solo lectura del repo (solo si el repo es privado)
# =============================================================================================

if [[ "${repo_url}" == https://* ]]; then
  ui_step "Paso 3 de 7: tu repo es público, la máquina lo baja sola (nada que hacer)"
else
  ui_step "Paso 3 de 7: llave de solo lectura para que la máquina baje tu repo privado"

  correr "${TOFU}" -chdir="${TF_DIR}" apply -input=false -auto-approve \
    -target=module.zomboid.tls_private_key.deploy

  deploy_key=""
  if [[ "${DRY_RUN}" -eq 0 ]]; then
    deploy_key="$(tofu_output deploy_public_key '^ssh-.*')"
  fi

  slug=""
  case "${repo_url}" in
    git@github.com:*)
      slug="${repo_url#git@github.com:}"
      slug="${slug%.git}"
      ;;
    ssh://git@github.com/*)
      slug="${repo_url#ssh://git@github.com/}"
      slug="${slug%.git}"
      ;;
  esac

  ya_cargada=0
  if [[ -n "${slug}" ]] && command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    if gh repo deploy-key list -R "${slug}" 2>/dev/null | grep -q 'zomboid-vm'; then
      ui_ok "la llave ya estaba cargada en GitHub"
      ya_cargada=1
    elif [[ "${DRY_RUN}" -eq 1 ]]; then
      echo "         (simulado) gh repo deploy-key add ... -R ${slug} --title zomboid-vm"
      ya_cargada=1
    elif [[ -n "${deploy_key}" ]]; then
      tmp_key="$(mktemp)"
      printf '%s\n' "${deploy_key}" >"${tmp_key}"
      if gh repo deploy-key add "${tmp_key}" --title zomboid-vm -R "${slug}"; then
        ui_ok "llave cargada en GitHub automáticamente"
        ya_cargada=1
      fi
      rm -f "${tmp_key}"
    fi
  fi

  if [[ "${ya_cargada}" -eq 0 ]]; then
    cat <<MANUAL

  Hay que darle permiso a la máquina para bajar tu repo privado. Es un copy/paste:

   1. Copiá esta línea entera (es una llave que solo sirve para LEER tu repo):

${deploy_key}

   2. Entrá a tu repo en GitHub -> Settings -> Deploy keys -> "Add deploy key".
   3. Title: zomboid-vm       Key: pegá la línea de arriba.
   4. NO marques "Allow write access".
   5. Apretá "Add key".

MANUAL
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      read -r -p "  Cuando la hayas cargado, apretá Enter para seguir: " _ || true
    fi
  fi
fi

# =============================================================================================
# 4. Crear la infraestructura
# =============================================================================================

ui_step "Paso 4 de 7: creando el servidor en Oracle Cloud"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "         (simulado) ${TOFU} -chdir=${TF_DIR} plan"
  echo "         (simulado) ${TOFU} -chdir=${TF_DIR} apply"
elif [[ "${SIN_PREGUNTAR}" -eq 1 ]]; then
  "${TOFU}" -chdir="${TF_DIR}" apply -input=false -auto-approve
else
  # El plan tiene contraseñas adentro: archivo temporal con permisos de solo el dueño.
  plan_file="$(mktemp -u)"
  (
    umask 077
    "${TOFU}" -chdir="${TF_DIR}" plan -input=false -out="${plan_file}"
  )
  cat <<'AVISO_PLATA'

  Arriba está la lista de lo que se va a crear en Oracle Cloud.
  A partir de acá SE EMPIEZA A COBRAR: alrededor de 90 USD por mes con la máquina prendida
  todo el tiempo. Para dejar de pagar en cualquier momento:  make destroy-all

AVISO_PLATA
  if ui_confirm "¿Creo el servidor?" n; then
    "${TOFU}" -chdir="${TF_DIR}" apply -input=false "${plan_file}"
    rm -f "${plan_file}"
  else
    rm -f "${plan_file}"
    ui_say "  Cancelado. No se creó nada."
    exit 0
  fi
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  ip="203.0.113.10"
else
  ip="$(tofu_output public_ip "${TF_RE_IP}")"
  [[ -n "${ip}" ]] || ui_die "el servidor se creó pero no pude leer su IP. Probá: ${TOFU} -chdir=${TF_DIR} output"
fi
ui_ok "IP del servidor: ${ip}"

# =============================================================================================
# 5. Esperar a que la máquina acepte conexiones
# =============================================================================================

ui_step "Paso 5 de 7: esperando a que la máquina prenda (hasta 10 minutos)"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "         (simulado) ssh ${VM_USER}@${ip} true  en un bucle hasta que responda"
else
  inicio="${SECONDS}"
  while true; do
    if ssh "${SSH_OPTS[@]}" "${VM_USER}@${ip}" true 2>/dev/null; then
      ui_ok "la máquina responde"
      break
    fi
    if ((SECONDS - inicio > ESPERA_SSH_SEG)); then
      cat <<TIMEOUT

  La máquina no respondió en 10 minutos. Cosas para revisar:
    - ¿Cambió tu IP de internet? Corré ./setup.sh de nuevo y después make deploy.
    - En la consola de Oracle, ¿la instancia figura como RUNNING?
    - Más ayuda: docs/runbook.md, sección "No entra por SSH".

TIMEOUT
      exit 1
    fi
    printf '  ... esperando (%d min)\r' "$(((SECONDS - inicio) / 60))"
    sleep 15
  done
fi

# =============================================================================================
# 6. Esperar a que el juego arranque
# =============================================================================================

ui_step "Paso 6 de 7: instalando y arrancando el juego (hasta 30 minutos la primera vez)"

cat <<'PACIENCIA'
         Esto tarda porque la máquina baja el juego entero (unos 10 GB) y lo instala.
         Podés dejarlo corriendo e ir a hacer otra cosa. Si cortás con Ctrl+C no rompés
         nada: el servidor sigue instalándose solo y podés volver con  make deploy.
PACIENCIA

if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo "         (simulado) ssh ${VM_USER}@${ip} 'cd /opt/zomboid-server && docker compose logs zomboid'"
  echo "         (simulado) hasta ver '*** SERVER STARTED ****' o cortar a los 30 minutos"
else
  inicio="${SECONDS}"
  listo=0
  while ((SECONDS - inicio <= ESPERA_JUEGO_SEG)); do
    if ssh "${SSH_OPTS[@]}" "${VM_USER}@${ip}" \
      "cd /opt/zomboid-server 2>/dev/null && docker compose logs --no-log-prefix zomboid 2>/dev/null | grep -q 'SERVER STARTED'" 2>/dev/null; then
      listo=1
      break
    fi

    # Mientras tanto, se cuenta qué está pasando en palabras.
    fase="$(ssh "${SSH_OPTS[@]}" "${VM_USER}@${ip}" \
      'cloud-init status 2>/dev/null | head -1' 2>/dev/null || true)"
    case "${fase}" in
      *running*) detalle="preparando la máquina y bajando el juego" ;;
      *done*) detalle="arrancando el juego" ;;
      *error*)
        cat <<'ERRORCI'

  La preparación de la máquina falló. Para ver por qué:

    ssh USUARIO@IP 'sudo tail -50 /var/log/cloud-init-output.log'

  El caso más común es que la llave de solo lectura del repo no esté cargada en GitHub.
  Más ayuda: docs/runbook.md, "El server no arranca después de un tofu apply".

ERRORCI
        exit 1
        ;;
      *) detalle="preparando la máquina" ;;
    esac
    printf '  ... %s (%d min)          \r' "${detalle}" "$(((SECONDS - inicio) / 60))"
    sleep 20
  done
  echo

  if [[ "${listo}" -eq 0 ]]; then
    cat <<'LENTO'

  Pasaron 30 minutos y el juego todavía no terminó de arrancar. No necesariamente está roto:
  con una conexión lenta el primer arranque puede tardar más. Para mirar en vivo qué hace:

    make remote-logs

  Volvé a correr  make deploy  cuando quieras y retoma desde acá.

LENTO
    exit 1
  fi
  ui_ok "el juego está arriba"
fi

# =============================================================================================
# 7. Datos para los amigos
# =============================================================================================

ui_step "Paso 7 de 7: listo"

cat <<FINAL

  ============================================================
   PASALE ESTO A TUS AMIGOS
  ============================================================

   En Project Zomboid: Join -> pestaña Favorites -> Add server

     Nombre .................. ${public_name}
     IP ...................... ${ip}
     Puerto .................. ${GAME_PORT}
     Contraseña del server ... ${server_password}

     El "Account username" y "Account password" los elige cada uno: son suyos y se crean
     solos la primera vez que entran.

  ============================================================
   TUS 5 COMANDOS
  ============================================================

     make remote-status      ¿está arriba? ¿quién está jugando?
     make remote-logs        ver qué está pasando (Ctrl+C para salir)
     make remote-restart     reiniciar (aplica cambios de mods o de reglas)
     make remote-backup      guardar una copia de la partida ahora mismo
     make destroy-all        borrar todo y dejar de pagar

   Para agregar mods: editá config/mods.txt (formato adentro del archivo) y corré  make sync RESTART=1
   Manual completo: README.md      Referencia avanzada: docs/runbook.md

FINAL
