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
      printf '%s\n' "$(t deploy.help)"
      exit 0
      ;;
    *) ui_die "$(t deploy.unknown_option "${arg}")" ;;
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
    printf '%s\n' "$(t deploy.simulated "$*")"
    return 0
  fi
  "$@"
}

# =============================================================================================
# 1. Revisión previa
# =============================================================================================

ui_step "$(t deploy.step1)"

if "${REPO_DIR}/scripts/doctor.sh" --quiet; then
  ui_ok "$(t deploy.ok)"
elif [[ "${DRY_RUN}" -eq 1 ]]; then
  ui_warn "$(t deploy.dryrun_warn)"
else
  printf '%s\n\n' "$(t deploy.blocked)"
  exit 1
fi

[[ -f "${TFVARS}" || "${DRY_RUN}" -eq 1 ]] || ui_die "$(t deploy.no_tfvars "${TFVARS}")"

repo_url="$(tfvar repo_url)"
server_password="$(tfvar server_password)"
public_name="$(tfvar public_name)"
[[ -n "${repo_url}" ]] || repo_url="https://github.com/lucbece/zomboid-server.git"

# =============================================================================================
# 2. Preparar OpenTofu
# =============================================================================================

ui_step "$(t deploy.step2)"
correr "${TOFU}" -chdir="${TF_DIR}" init -input=false

# =============================================================================================
# 3. Llave de solo lectura del repo (solo si el repo es privado)
# =============================================================================================

if [[ "${repo_url}" == https://* ]]; then
  ui_step "$(t deploy.step3.public)"
else
  ui_step "$(t deploy.step3.private)"

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
      ui_ok "$(t deploy.key.loaded)"
      ya_cargada=1
    elif [[ "${DRY_RUN}" -eq 1 ]]; then
      printf '%s\n' "$(t deploy.simulated "$(t deploy.key.simulated "${slug}")")"
      ya_cargada=1
    elif [[ -n "${deploy_key}" ]]; then
      tmp_key="$(mktemp)"
      printf '%s\n' "${deploy_key}" >"${tmp_key}"
      if gh repo deploy-key add "${tmp_key}" --title zomboid-vm -R "${slug}"; then
        ui_ok "$(t deploy.key.added)"
        ya_cargada=1
      fi
      rm -f "${tmp_key}"
    fi
  fi

  if [[ "${ya_cargada}" -eq 0 ]]; then
    printf '%s\n\n' "$(t deploy.key.manual "${deploy_key}")"
    if [[ "${DRY_RUN}" -eq 0 ]]; then
      read -r -p "$(t deploy.key.prompt)" _ || true
    fi
  fi
fi

# =============================================================================================
# 4. Crear la infraestructura
# =============================================================================================

ui_step "$(t deploy.step4)"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '%s\n' "$(t deploy.simulated "${TOFU} -chdir=${TF_DIR} plan")"
  printf '%s\n' "$(t deploy.simulated "${TOFU} -chdir=${TF_DIR} apply")"
elif [[ "${SIN_PREGUNTAR}" -eq 1 ]]; then
  "${TOFU}" -chdir="${TF_DIR}" apply -input=false -auto-approve
else
  # El plan tiene contraseñas adentro: archivo temporal con permisos de solo el dueño.
  plan_file="$(mktemp -u)"
  (
    umask 077
    "${TOFU}" -chdir="${TF_DIR}" plan -input=false -out="${plan_file}"
  )
  printf '%s\n\n' "$(t deploy.money)"
  if ui_confirm "$(t deploy.confirm)" n; then
    "${TOFU}" -chdir="${TF_DIR}" apply -input=false "${plan_file}"
    rm -f "${plan_file}"
  else
    rm -f "${plan_file}"
    ui_say "$(t deploy.cancelled)"
    exit 0
  fi
fi

if [[ "${DRY_RUN}" -eq 1 ]]; then
  ip="203.0.113.10"
else
  ip="$(tofu_output public_ip "${TF_RE_IP}")"
  [[ -n "${ip}" ]] || ui_die "$(t deploy.ip_fail "${TOFU}" "${TF_DIR}")"
fi
ui_ok "$(t deploy.ip "${ip}")"

# =============================================================================================
# 5. Esperar a que la máquina acepte conexiones
# =============================================================================================

ui_step "$(t deploy.step5)"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '%s\n' "$(t deploy.simulated "$(t deploy.ssh.simulated "${VM_USER}" "${ip}")")"
else
  inicio="${SECONDS}"
  while true; do
    if ssh "${SSH_OPTS[@]}" "${VM_USER}@${ip}" true 2>/dev/null; then
      ui_ok "$(t deploy.ssh_ok)"
      break
    fi
    if ((SECONDS - inicio > ESPERA_SSH_SEG)); then
      printf '%s\n\n' "$(t deploy.ssh_timeout)"
      exit 1
    fi
    printf '  ... %s (%d min)\r' "$(t deploy.waiting)" "$(((SECONDS - inicio) / 60))"
    sleep 15
  done
fi

# =============================================================================================
# 6. Esperar a que el juego arranque
# =============================================================================================

ui_step "$(t deploy.step6)"

printf '%s\n' "$(t deploy.patience)"

if [[ "${DRY_RUN}" -eq 1 ]]; then
  printf '%s\n' "$(t deploy.simulated "$(t deploy.logs.simulated "${VM_USER}" "${ip}")")"
  printf '%s\n' "$(t deploy.simulated "$(t deploy.logs.simulated2)")"
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
      *running*) detalle="$(t deploy.phase.preparing)" ;;
      *done*) detalle="$(t deploy.phase.starting)" ;;
      *error*)
        printf '%s\n\n' "$(t deploy.cloudinit_error)"
        exit 1
        ;;
      *) detalle="$(t deploy.phase.default)" ;;
    esac
    printf '  ... %s (%d min)          \r' "${detalle}" "$(((SECONDS - inicio) / 60))"
    sleep 20
  done
  echo

  if [[ "${listo}" -eq 0 ]]; then
    printf '%s\n\n' "$(t deploy.slow)"
    exit 1
  fi
  ui_ok "$(t deploy.game_up)"
fi

# =============================================================================================
# 7. Datos para los amigos
# =============================================================================================

ui_step "$(t deploy.step7)"

printf '%s\n\n' "$(t deploy.final "${public_name}" "${ip}" "${GAME_PORT}" "${server_password}")"
