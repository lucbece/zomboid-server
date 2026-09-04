#!/usr/bin/env bash
# Revisa que esté todo listo para desplegar y operar el server, y explica en una línea qué
# hacer con cada cosa que falta.
#
#   make doctor            # revisión completa, en castellano
#   scripts/doctor.sh -q   # solo lo que está mal (lo usa scripts/deploy.sh antes de arrancar)
#
# Códigos de salida:
#   0  todo lo bloqueante está en orden (puede haber AVISOs)
#   1  falta algo sin lo cual `make deploy` no puede funcionar
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_DIR}"

# shellcheck source=scripts/lib/ui.sh
source "${REPO_DIR}/scripts/lib/ui.sh"
# shellcheck source=scripts/lib/oci-instance.sh
source "${REPO_DIR}/scripts/lib/oci-instance.sh"

TF_DIR="${TF_ENV_DIR}"
TFVARS="${TF_DIR}/terraform.tfvars"
ENV_FILE="${REPO_DIR}/.env"
OCI_CONFIG="${OCI_CLI_CONFIG_FILE:-${HOME}/.oci/config}"
TOFU="${TOFU:-tofu}"

QUIET=0
for arg in "$@"; do
  case "${arg}" in
    -q | --quiet) QUIET=1 ;;
    -h | --help | --ayuda)
      sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) ui_die "opción desconocida: ${arg}" ;;
  esac
done

export PATH="${HOME}/.local/bin:${PATH}"

PROBLEMAS=0

# En modo -q solo se imprimen los AVISO y los FALTA (con su linea de accion): los OK se callan,
# y las lineas de accion que cuelgan de un OK tambien.
ULTIMO_FUE_OK=0
say_title() { [[ "${QUIET}" -eq 1 ]] || ui_title "$@"; }
say_ok() {
  ULTIMO_FUE_OK=1
  [[ "${QUIET}" -eq 1 ]] || ui_ok "$@"
}
say_warn() {
  ULTIMO_FUE_OK=0
  ui_warn "$@"
}
say_miss() {
  ULTIMO_FUE_OK=0
  ui_miss "$@"
  PROBLEMAS=$((PROBLEMAS + 1))
}
say_hint() {
  [[ "${QUIET}" -eq 1 && "${ULTIMO_FUE_OK}" -eq 1 ]] && return 0
  ui_hint "$@"
}

# Lee un valor de terraform.tfvars.
tfvar() {
  [[ -f "${TFVARS}" ]] || return 0
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"# ])\"?[[:space:]]*(#.*)?$/\1/p" \
    "${TFVARS}" | head -1
}

[[ "${QUIET}" -eq 1 ]] || cat <<'CABECERA'

  ============================================================
   Revisión del server de Project Zomboid
  ============================================================
CABECERA

# =============================================================================================
# 1. Programas
# =============================================================================================

say_title "1. Programas necesarios"

if ((BASH_VERSINFO[0] >= 4)); then
  say_ok "bash ${BASH_VERSION%%(*}"
else
  say_miss "bash ${BASH_VERSION%%(*} es muy viejo (hace falta 4 o más)"
  say_hint "En macOS:  brew install bash"
fi

for cmd in git curl make ssh rsync; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    say_ok "${cmd}"
  else
    say_miss "falta ${cmd}"
    say_hint "Instalalo con:  sudo apt install ${cmd}"
  fi
done

if command -v "${TOFU}" >/dev/null 2>&1; then
  say_ok "OpenTofu $("${TOFU}" version | head -1 | awk '{print $2}')"
else
  say_miss "falta OpenTofu (es el programa que crea la máquina en la nube)"
  say_hint "Corré ./setup.sh: te lo instala solo en ~/.local/bin"
fi

# Clave SSH: sin ella no se puede entrar a la máquina.
ssh_pub=""
for f in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_ecdsa.pub" "${HOME}/.ssh/id_rsa.pub"; do
  [[ -f "${f}" ]] && {
    ssh_pub="${f}"
    break
  }
done
if [[ -n "${ssh_pub}" ]]; then
  say_ok "clave SSH: ${ssh_pub}"
else
  say_miss "no tenés clave SSH (es lo que te deja entrar a la máquina)"
  say_hint "Creala con:  ssh-keygen -t ed25519"
fi

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  say_ok "GitHub CLI conectado (opcional: sirve para cargar la llave del repo privado)"
else
  say_warn "GitHub CLI (gh) no está o no está conectado: es opcional"
  say_hint "Solo hace falta si tu repo es privado. Se puede hacer a mano desde la web."
fi

# =============================================================================================
# 2. Cuenta de Oracle Cloud
# =============================================================================================

say_title "2. Cuenta de Oracle Cloud"

oci_ok=0
if [[ -f "${OCI_CONFIG}" ]]; then
  if grep -qE '^\[DEFAULT\]' "${OCI_CONFIG}"; then
    say_ok "${OCI_CONFIG} con perfil [DEFAULT]"
  else
    say_miss "${OCI_CONFIG} no tiene un perfil [DEFAULT]"
    say_hint "La primera línea del archivo tiene que ser exactamente:  [DEFAULT]"
  fi

  key_file="$(sed -n -E 's/^[[:space:]]*key_file[[:space:]]*=[[:space:]]*(.*)$/\1/p' "${OCI_CONFIG}" | head -1)"
  key_file="${key_file/#\~/${HOME}}"
  if [[ -n "${key_file}" && -f "${key_file}" ]]; then
    say_ok "clave privada de la API: ${key_file}"
  else
    say_miss "la línea key_file= de ${OCI_CONFIG} no apunta a un archivo que exista"
    say_hint "Poné la ruta completa del .pem que bajaste de Oracle, por ejemplo ${HOME}/.oci/oci_api_key.pem"
  fi
else
  say_miss "no existe ${OCI_CONFIG}: la computadora no está conectada a tu cuenta de Oracle"
  say_hint "Corré ./setup.sh: te guía paso a paso para crear la API key."
fi

if command -v oci >/dev/null 2>&1; then
  say_ok "programa 'oci' instalado"
  if [[ -f "${OCI_CONFIG}" ]]; then
    if oci iam region-subscription list >/dev/null 2>&1; then
      say_ok "Oracle acepta tu clave: la cuenta responde"
      oci_ok=1
    else
      say_miss "Oracle no acepta tu clave todavía"
      say_hint "Para ver el error completo:  oci iam region-subscription list"
      say_hint "Revisá user=, fingerprint=, tenancy= y key_file= en ${OCI_CONFIG}."
    fi
  fi
else
  say_warn "el programa 'oci' no está instalado"
  say_hint "No es imprescindible para desplegar, pero sirve para prender/apagar el server."
  say_hint "Corré ./setup.sh y aceptá instalarlo (queda en ~/.venvs/oci, sin sudo)."
fi

# =============================================================================================
# 3. Configuración de tu server
# =============================================================================================

say_title "3. Configuración de tu server"

if [[ -f "${TFVARS}" ]]; then
  say_ok "infra/terraform/envs/prod/terraform.tfvars"
  if grep -q 'CAMBIAME' "${TFVARS}"; then
    say_miss "terraform.tfvars todavía tiene valores de ejemplo (dice CAMBIAME)"
    say_hint "Corré ./setup.sh para completarlo."
  fi
  for clave in tenancy_ocid admin_cidr ssh_public_key alert_email server_password; do
    if [[ -z "$(tfvar "${clave}")" ]]; then
      say_miss "falta ${clave} en terraform.tfvars"
      say_hint "Corré ./setup.sh."
    fi
  done
  perms="$(stat -c '%a' "${TFVARS}" 2>/dev/null || echo '')"
  if [[ -n "${perms}" && "${perms}" != "600" ]]; then
    say_warn "terraform.tfvars tiene permisos ${perms}: tiene contraseñas adentro"
    say_hint "Arreglalo con:  chmod 600 ${TFVARS}"
  fi
else
  say_miss "no existe terraform.tfvars: el server no está configurado"
  say_hint "Corré ./setup.sh."
fi

if [[ -f "${ENV_FILE}" ]]; then
  say_ok ".env"
else
  say_warn "no existe .env"
  say_hint "Solo hace falta para correr el server en esta computadora. Lo crea ./setup.sh."
fi

MODS_FILE="${REPO_DIR}/config/mods.txt"
if [[ -f "${MODS_FILE}" ]]; then
  mods_n="$(grep -cE '^[[:space:]]*[0-9]+' "${MODS_FILE}" || true)"
  if [[ "${mods_n}" -gt 0 ]]; then
    say_ok "config/mods.txt: ${mods_n} mods del Workshop"
  else
    say_ok "config/mods.txt: sin mods activos (partida vanilla)"
    say_hint "Para agregar mods, editá config/mods.txt (el formato está adentro y en docs/mods.md)."
  fi
else
  say_warn "no existe config/mods.txt: la partida va a ser vanilla (sin mods)"
  say_hint "Lo crea ./setup.sh, o:  cp config/mods.example.txt config/mods.txt"
fi

# --- El repo tiene que estar accesible desde la máquina de la nube ------------------------------
repo_url="$(tfvar repo_url)"
if [[ -n "${repo_url}" ]]; then
  if [[ "${repo_url}" == https://* ]]; then
    if GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      git ls-remote "${repo_url}" HEAD >/dev/null 2>&1; then
      say_ok "el repo ${repo_url} es público: la máquina lo va a poder bajar"
    else
      say_miss "el repo ${repo_url} no se puede bajar sin contraseña"
      say_hint "Hacelo público en GitHub -> Settings -> General -> Change visibility,"
      say_hint "o volvé a correr ./setup.sh para usar una llave de solo lectura."
    fi
  else
    say_ok "el repo ${repo_url} se baja por SSH con una llave de solo lectura"
    if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
      slug="${repo_url#git@github.com:}"
      slug="${slug%.git}"
      if gh repo deploy-key list -R "${slug}" >/dev/null 2>&1; then
        if [[ -n "$(gh repo deploy-key list -R "${slug}" 2>/dev/null)" ]]; then
          say_ok "el repo ya tiene una llave de solo lectura cargada en GitHub"
        else
          say_warn "el repo todavía no tiene ninguna llave cargada en GitHub"
          say_hint "'make deploy' la va a cargar por vos."
        fi
      fi
    fi
  fi
else
  say_warn "no pude leer repo_url de terraform.tfvars"
fi

# =============================================================================================
# 4. Estado del server en la nube (solo si ya lo desplegaste)
# =============================================================================================

instance_ocid="$(tofu_output instance_ocid "${TF_RE_OCID}")"

if [[ -z "${instance_ocid}" ]]; then
  say_title "4. Server en la nube"
  say_ok "todavía no desplegaste nada (no hay nada creado ni nada que se esté cobrando)"
  say_hint "Cuando quieras crearlo:  make deploy"
else
  say_title "4. Server en la nube"
  public_ip="$(tofu_output public_ip "${TF_RE_IP}")"
  say_ok "IP del server: ${public_ip:-desconocida}"

  if [[ "${oci_ok}" -eq 1 ]]; then
    estado="$(oci compute instance get --instance-id "${instance_ocid}" \
      --query 'data."lifecycle-state"' --raw-output 2>/dev/null || true)"
    case "${estado}" in
      RUNNING)
        say_ok "la máquina está PRENDIDA (y se está cobrando)"
        say_hint "Para ver si el juego responde:  make remote-status"
        ;;
      STOPPED)
        say_ok "la máquina está APAGADA (no se cobra cómputo, solo el disco)"
        say_hint "Para prenderla:  ./scripts/cloud-start.sh"
        ;;
      "")
        say_warn "no pude consultar el estado de la máquina"
        say_hint "Probá:  oci compute instance get --instance-id ${instance_ocid}"
        ;;
      *) say_warn "estado de la máquina: ${estado}" ;;
    esac

    bucket="$(tofu_output bucket_name "${TF_RE_NOMBRE}")"
    ns="$(tofu_output bucket_namespace "${TF_RE_NOMBRE}")"
    if [[ -n "${bucket}" && -n "${ns}" ]]; then
      ultimo="$(oci os object list --bucket-name "${bucket}" --namespace "${ns}" \
        --fields timeCreated --query 'sort_by(data, &"time-created")[-1].name' \
        --raw-output 2>/dev/null || true)"
      if [[ -n "${ultimo}" && "${ultimo}" != "null" ]]; then
        say_ok "último backup guardado: ${ultimo}"
      else
        say_warn "todavía no hay ningún backup en la nube (bucket ${bucket})"
        say_hint "El backup automático corre todos los días. Para forzar uno:  make remote-backup"
      fi
    fi
  else
    say_warn "no puedo consultar el estado de la máquina sin el programa 'oci' configurado"
  fi
fi

# =============================================================================================
# Resumen
# =============================================================================================

if [[ "${PROBLEMAS}" -eq 0 ]]; then
  [[ "${QUIET}" -eq 1 ]] || cat <<'FINAL'

  ------------------------------------------------------------
   Está todo listo. El siguiente paso es:   make deploy
  ------------------------------------------------------------

FINAL
  exit 0
fi

cat <<FINAL

  ------------------------------------------------------------
   Hay ${PROBLEMAS} cosa(s) marcada(s) como FALTA más arriba.
   Arreglalas (casi siempre alcanza con correr ./setup.sh) y volvé a probar con: make doctor
  ------------------------------------------------------------

FINAL
exit 1
