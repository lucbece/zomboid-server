#!/usr/bin/env bash
# Asistente de configuracion del servidor de Project Zomboid.
#
#   ./setup.sh                 # modo normal: te va preguntando y te explica cada cosa
#   ./setup.sh --no-preguntar  # no pregunta nada: usa los valores de las variables ZS_*
#   ./setup.sh --ayuda
#
# Que hace: revisa que estén las herramientas, te ayuda a conectar tu cuenta de Oracle Cloud,
# inventa las contraseñas por vos y escribe los dos archivos de configuración que necesita el
# deploy:
#
#   infra/terraform/envs/prod/terraform.tfvars   (lo lee OpenTofu para crear la máquina)
#   .env                                          (config del server; el de la nube lo genera
#                                                  cloud-init a partir del tfvars)
#
# Se puede volver a correr las veces que haga falta: te muestra lo que ya elegiste como
# respuesta por defecto y solo cambia lo que cambies.
#
# Modo --no-preguntar (lo usan las pruebas y el CI). Variables aceptadas:
#   ZS_LANG         idioma del CLI: es o en (ver scripts/lib/i18n.sh)
#   ZS_PUBLIC_NAME  ZS_MAX_PLAYERS  ZS_OCPUS  ZS_MEMORY_GB  ZS_ALERT_EMAIL  ZS_BUDGET_USD
#   ZS_REGION
#   ZS_TENANCY_OCID  ZS_ADMIN_CIDR  ZS_SSH_PUBLIC_KEY  ZS_REPO_URL  ZS_BUCKET_NAME
#   ZS_ADMIN_PASSWORD  ZS_RCON_PASSWORD  ZS_SERVER_PASSWORD
#   ZS_SKIP_OCI=1     no valida ~/.oci/config ni el CLI oci
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_DIR}"

# shellcheck source=scripts/lib/ui.sh
source "${REPO_DIR}/scripts/lib/ui.sh"
# shellcheck source=scripts/lib/palabras.sh
source "${REPO_DIR}/scripts/lib/palabras.sh"

TFVARS="${REPO_DIR}/infra/terraform/envs/prod/terraform.tfvars"
ENV_FILE="${REPO_DIR}/.env"
OCI_CONFIG="${OCI_CLI_CONFIG_FILE:-${HOME}/.oci/config}"
TOFU_VERSION="1.12.6"

PREGUNTAR=1

for arg in "$@"; do
  case "${arg}" in
    --no-preguntar | --non-interactive | -n) PREGUNTAR=0 ;;
    --ayuda | --help | -h)
      printf '%s\n' "$(t setup.help)"
      exit 0
      ;;
    *) ui_die "$(t setup.unknown_option "${arg}")" ;;
  esac
done

# =============================================================================================
# Utilidades
# =============================================================================================

# preguntar <texto> <default> -> imprime la respuesta. El prompt de `read -p` va a stderr,
# así que se puede capturar con $(...) sin ensuciar el valor.
preguntar() {
  local texto="$1" def="${2:-}" ans=""
  if [[ "${PREGUNTAR}" -eq 0 ]]; then
    echo "${def}"
    return 0
  fi
  if [[ -n "${def}" ]]; then
    read -r -p "  ${texto} [${def}]: " ans || true
  else
    read -r -p "  ${texto}: " ans || true
  fi
  echo "${ans:-${def}}"
}

pausa() {
  [[ "${PREGUNTAR}" -eq 1 ]] || return 0
  read -r -p "  ${1:-$(t setup.pause.default)} " _ || true
}

# Numero aleatorio en [0, n). Usa /dev/urandom; si no se puede leer, cae a $RANDOM.
azar() {
  local n="$1" r=""
  r="$(od -An -N4 -tu4 </dev/urandom 2>/dev/null | tr -dc '0-9')" || true
  [[ -n "${r}" ]] || r="${RANDOM}${RANDOM}"
  echo "$((10#${r} % n))"
}

# Password legible: tres palabras y cuatro dígitos, "arena-tulipan-molino-4821".
# Cumple la validación del módulo de OpenTofu: 8-64 caracteres, sin espacios ni comillas.
generar_password() {
  local total="${#PALABRAS[@]}" i out=""
  for _ in 1 2 3; do
    i="$(azar "${total}")"
    out="${out}${PALABRAS[${i}]}-"
  done
  printf '%s%04d\n' "${out}" "$(azar 10000)"
}

# Mismo juego de caracteres que valida infra/terraform/modules/oci/variables.tf: el .env lo
# parsean bash y docker compose, que no escapan igual.
RE_PASSWORD='^[A-Za-z0-9._@#%^&*()+=:,/-]{8,64}$'
RE_NOMBRE='^[^"\\$`]{1,64}$'
RE_SSH_PUB='^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256) '
RE_IP='^[0-9]{1,3}(\.[0-9]{1,3}){3}$'
RE_CIDR='^[0-9]{1,3}(\.[0-9]{1,3}){3}/[0-9]{1,2}$'

password_valida() { [[ "$1" =~ $RE_PASSWORD ]]; }

# Lee un valor de terraform.tfvars:  clave = "valor"  ó  clave = 123
tfvar_actual() {
  [[ -f "${TFVARS}" ]] || return 0
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"# ])\"?[[:space:]]*(#.*)?$/\1/p" \
    "${TFVARS}" | head -1
}

# Lee un valor de ~/.oci/config (perfil DEFAULT).
oci_config_valor() {
  [[ -f "${OCI_CONFIG}" ]] || return 0
  sed -n -E "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*(.*)$/\1/p" "${OCI_CONFIG}" | head -1
}

# Valor final de un campo: variable de entorno ZS_* > lo que ya está en tfvars > default.
elegir() {
  local var="$1" clave="$2" def="${3:-}" actual=""
  if [[ -n "${var}" && -n "${!var:-}" ]]; then
    echo "${!var}"
    return 0
  fi
  actual="$(tfvar_actual "${clave}")"
  if [[ -n "${actual}" && "${actual}" != *CAMBIAME* ]]; then
    echo "${actual}"
  else
    echo "${def}"
  fi
}

# =============================================================================================
# Idioma
# =============================================================================================
# Va antes que todo lo demas: define en que idioma sale el resto del asistente. La pregunta
# es bilingue a proposito, porque todavia no se sabe que idioma habla quien la lee. El valor
# por defecto es el que resolvio scripts/lib/i18n.sh (entorno, .env de una corrida anterior o
# el locale del sistema).

zs_lang="$(preguntar "$(t setup.q.lang) [es/en]" "${ZS_LANG}")"
case "${zs_lang}" in
  es | en) ;;
  *) zs_lang="en" ;;
esac
i18n_load "${zs_lang}"

# =============================================================================================
# 0. Bienvenida
# =============================================================================================

printf '%s\n\n' "$(t setup.welcome)"

pausa "$(t setup.pause.start)"

# =============================================================================================
# 1. Herramientas
# =============================================================================================

ui_title "$(t setup.tools.title)"

faltan_bloqueantes=0

for cmd in git curl make ssh rsync; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    ui_ok "${cmd}"
  else
    ui_miss "${cmd}"
    ui_hint "$(t setup.tools.install_hint "${cmd}")"
    faltan_bloqueantes=1
  fi
done

if ((BASH_VERSINFO[0] >= 4)); then
  ui_ok "bash ${BASH_VERSION%%(*}"
else
  ui_miss "$(t setup.bash.old "${BASH_VERSION%%(*}")"
  ui_hint "$(t setup.bash.macos)"
  faltan_bloqueantes=1
fi

[[ "${faltan_bloqueantes}" -eq 0 ]] || ui_die "$(t setup.tools.missing)"

# --- OpenTofu ---------------------------------------------------------------------------------
# Es el programa que crea la máquina en la nube leyendo la carpeta infra/.
export PATH="${HOME}/.local/bin:${PATH}"

instalar_tofu() {
  local tmp
  command -v unzip >/dev/null 2>&1 || {
    ui_hint "$(t setup.tofu.unzip)"
    return 1
  }
  tmp="$(mktemp -d)"
  ui_say "$(t setup.tofu.downloading "${TOFU_VERSION}")"
  (
    cd "${tmp}"
    curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_amd64.zip"
    curl -fsSLO "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_SHA256SUMS"
    sha256sum -c --ignore-missing "tofu_${TOFU_VERSION}_SHA256SUMS"
    unzip -oq "tofu_${TOFU_VERSION}_linux_amd64.zip" tofu
    mkdir -p "${HOME}/.local/bin"
    install -m 755 tofu "${HOME}/.local/bin/tofu"
  )
  rm -rf "${tmp}"
}

if command -v tofu >/dev/null 2>&1; then
  ui_ok "$(t setup.tofu.ok "$(tofu version | head -1 | awk '{print $2}')")"
else
  ui_miss "$(t setup.tofu.missing)"
  if [[ "${PREGUNTAR}" -eq 1 ]] && ui_confirm "$(t setup.tofu.confirm)" s; then
    if instalar_tofu; then
      ui_ok "$(t setup.tofu.installed)"
    else
      ui_die "$(t setup.tofu.install_failed)"
    fi
  else
    ui_hint "$(t setup.tofu.manual)"
    ui_die "$(t setup.tofu.required)"
  fi
fi

# --- Clave SSH --------------------------------------------------------------------------------
# Es el "candado" con el que tu computadora entra a la máquina de la nube.
elegir_clave_ssh() {
  local f
  for f in "${HOME}/.ssh/id_ed25519.pub" "${HOME}/.ssh/id_ecdsa.pub" "${HOME}/.ssh/id_rsa.pub"; do
    [[ -f "${f}" ]] && {
      echo "${f}"
      return 0
    }
  done
  return 1
}

ssh_pub_file=""
if [[ -n "${ZS_SSH_PUBLIC_KEY:-}" ]]; then
  ui_ok "$(t setup.ssh.from_env)"
elif ssh_pub_file="$(elegir_clave_ssh)"; then
  ui_ok "$(t setup.ssh.found "${ssh_pub_file}")"
else
  ui_miss "$(t setup.ssh.missing)"
  if [[ "${PREGUNTAR}" -eq 1 ]] && ui_confirm "$(t setup.ssh.confirm)" s; then
    ssh-keygen -t ed25519 -N '' -C "zomboid-server" -f "${HOME}/.ssh/id_ed25519"
    ssh_pub_file="${HOME}/.ssh/id_ed25519.pub"
    ui_ok "$(t setup.ssh.created "${ssh_pub_file}")"
  else
    ui_die "$(t setup.ssh.required)"
  fi
fi

ssh_public_key="${ZS_SSH_PUBLIC_KEY:-}"
if [[ -z "${ssh_public_key}" && -n "${ssh_pub_file}" ]]; then
  ssh_public_key="$(tr -d '\n' <"${ssh_pub_file}")"
fi
[[ "${ssh_public_key}" =~ $RE_SSH_PUB ]] ||
  ui_die "$(t setup.ssh.bad_format)"

# --- gh (opcional) ----------------------------------------------------------------------------
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  ui_ok "$(t setup.gh.ok)"
else
  ui_warn "$(t setup.gh.missing)"
fi

# =============================================================================================
# 2. Cuenta de Oracle Cloud
# =============================================================================================

ui_title "$(t setup.oci.title)"

instalar_oci_cli() {
  command -v python3 >/dev/null 2>&1 || {
    ui_hint "$(t setup.oci.python)"
    return 1
  }
  python3 -m venv "${HOME}/.venvs/oci"
  "${HOME}/.venvs/oci/bin/pip" install --quiet --upgrade pip oci-cli
  mkdir -p "${HOME}/.local/bin"
  ln -sf "${HOME}/.venvs/oci/bin/oci" "${HOME}/.local/bin/oci"
}

if [[ -n "${ZS_SKIP_OCI:-}" ]]; then
  ui_warn "$(t setup.oci.skipped)"
else
  if [[ ! -f "${OCI_CONFIG}" ]]; then
    printf '%s\n\n' "$(t setup.oci.apikey)"
    pausa "$(t setup.oci.pause)"
  fi

  if [[ -f "${OCI_CONFIG}" ]]; then
    ui_ok "$(t setup.oci.config_ok "${OCI_CONFIG}")"
    key_file="$(oci_config_valor key_file)"
    if [[ -n "${key_file}" && -f "${key_file/#\~/${HOME}}" ]]; then
      ui_ok "$(t setup.oci.key_ok "${key_file}")"
    else
      ui_warn "$(t setup.oci.key_bad "${OCI_CONFIG}")"
      ui_hint "$(t setup.oci.key_hint)"
    fi
  else
    ui_warn "$(t setup.oci.config_missing "${OCI_CONFIG}")"
  fi

  if command -v oci >/dev/null 2>&1; then
    ui_ok "$(t setup.oci.cli_ok)"
  else
    ui_warn "$(t setup.oci.cli_missing)"
    if [[ "${PREGUNTAR}" -eq 1 ]] && ui_confirm "$(t setup.oci.cli_confirm)" s; then
      if instalar_oci_cli; then
        ui_ok "$(t setup.oci.cli_installed)"
      else
        ui_warn "$(t setup.oci.cli_failed)"
      fi
    fi
  fi

  if command -v oci >/dev/null 2>&1 && [[ -f "${OCI_CONFIG}" ]]; then
    if oci iam region list --query 'data[0]' >/dev/null 2>&1; then
      ui_ok "$(t setup.oci.auth_ok)"
    else
      ui_warn "$(t setup.oci.auth_fail)"
      ui_hint "$(t setup.oci.auth_hint1 "${OCI_CONFIG}")"
      ui_hint "$(t setup.oci.auth_hint2)"
    fi
  fi
fi

# =============================================================================================
# 3. Preguntas
# =============================================================================================

ui_title "$(t setup.server.title)"

public_name="$(preguntar "$(t setup.q.public_name)" \
  "$(elegir ZS_PUBLIC_NAME public_name "$(t setup.default.public_name)")")"
[[ "${public_name}" =~ $RE_NOMBRE ]] ||
  ui_die "$(t setup.err.public_name)"

max_players="$(preguntar "$(t setup.q.max_players)" \
  "$(elegir ZS_MAX_PLAYERS max_players 8)")"
[[ "${max_players}" =~ ^[0-9]{1,3}$ ]] || ui_die "$(t setup.err.max_players)"

# Tamaño de la máquina y heap de la JVM, según cuántos jugadores va a haber. Una máquina más
# chica cuesta menos por hora, así que no tiene sentido pagar 4 OCPU para 6 amigos.
#
#   hasta 8 jugadores  -> 2 OCPU / 12 GB de RAM / heap 8g
#   más de 8           -> 4 OCPU / 16 GB de RAM / heap 12g
#
# El heap siempre deja ~4 GB para el sistema y para Docker. Se puede pisar todo con ZS_OCPUS
# y ZS_MEMORY_GB (el heap se recalcula: memoria de la VM menos 4 GB).
if ((max_players <= 8)); then
  ocpus=2
  memory_gb=12
else
  ocpus=4
  memory_gb=16
fi

ocpus="${ZS_OCPUS:-${ocpus}}"
memory_gb="${ZS_MEMORY_GB:-${memory_gb}}"
if [[ ! "${ocpus}" =~ ^[0-9]{1,3}$ ]] || ((ocpus < 1)); then
  ui_die "$(t setup.err.ocpus)"
fi
if [[ ! "${memory_gb}" =~ ^[0-9]{1,4}$ ]] || ((memory_gb < 6)); then
  ui_die "$(t setup.err.memory)"
fi

max_memory="$((memory_gb - 4))g"

alert_email="$(preguntar "$(t setup.q.alert_email)" \
  "$(elegir ZS_ALERT_EMAIL alert_email "")")"
[[ "${alert_email}" == *@*.* ]] || ui_die "$(t setup.err.alert_email)"

budget_usd="$(preguntar "$(t setup.q.budget)" \
  "$(elegir ZS_BUDGET_USD budget_usd 25)")"
[[ "${budget_usd}" =~ ^[0-9]+$ ]] || ui_die "$(t setup.err.budget)"

# --- Región -----------------------------------------------------------------------------------
# "codigo|clave del catalogo": la descripcion de cada region sale de scripts/lib/i18n/.
REGIONES=(
  "sa-saopaulo-1|setup.region.saopaulo"
  "sa-vinhedo-1|setup.region.vinhedo"
  "sa-santiago-1|setup.region.santiago"
  "us-ashburn-1|setup.region.ashburn"
  "us-phoenix-1|setup.region.phoenix"
  "eu-frankfurt-1|setup.region.frankfurt"
  "eu-madrid-1|setup.region.madrid"
  "uk-london-1|setup.region.london"
)

region_default="$(elegir ZS_REGION region "$(oci_config_valor region)")"
[[ -n "${region_default}" ]] || region_default="sa-saopaulo-1"

if [[ "${PREGUNTAR}" -eq 1 ]]; then
  printf '%s\n\n' "$(t setup.region.intro)"
  i=1
  for linea in "${REGIONES[@]}"; do
    printf '    %d) %-16s %s\n' "${i}" "${linea%%|*}" "$(t "${linea#*|}")"
    i=$((i + 1))
  done
  printf '%s\n\n' "$(t setup.region.warning)"
  eleccion="$(preguntar "$(t setup.q.region)" "${region_default}")"
  if [[ "${eleccion}" =~ ^[0-9]+$ ]] && ((eleccion >= 1 && eleccion <= ${#REGIONES[@]})); then
    linea="${REGIONES[$((eleccion - 1))]}"
    region="${linea%%|*}"
  else
    region="${eleccion}"
  fi
else
  region="${region_default}"
fi
[[ "${region}" =~ ^[a-z0-9-]+$ ]] || ui_die "$(t setup.err.region "${region}")"

if [[ -n "$(oci_config_valor region)" && "$(oci_config_valor region)" != "${region}" ]]; then
  ui_warn "$(t setup.region.mismatch "${region}" "$(oci_config_valor region)")"
  ui_hint "$(t setup.region.mismatch_hint)"
fi

# --- Tenancy y acceso --------------------------------------------------------------------------
tenancy_default="$(elegir ZS_TENANCY_OCID tenancy_ocid "$(oci_config_valor tenancy)")"
tenancy_ocid="$(preguntar "$(t setup.q.tenancy)" "${tenancy_default}")"
[[ "${tenancy_ocid}" == ocid1.tenancy.* ]] ||
  ui_die "$(t setup.err.tenancy "${OCI_CONFIG}")"

ip_publica=""
if [[ -z "${ZS_ADMIN_CIDR:-}" ]]; then
  ip_publica="$(curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null || true)"
  [[ "${ip_publica}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] ||
    ip_publica="$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
fi

admin_cidr_default="$(elegir ZS_ADMIN_CIDR admin_cidr "")"
if [[ -z "${ZS_ADMIN_CIDR:-}" && "${ip_publica}" =~ $RE_IP ]]; then
  admin_cidr_default="${ip_publica}/32"
fi
[[ -n "${admin_cidr_default}" ]] || ui_die "$(t setup.err.no_ip)"

printf '%s\n' "$(t setup.admin_cidr.intro)"
admin_cidr="$(preguntar "$(t setup.q.admin_cidr)" "${admin_cidr_default}")"
[[ "${admin_cidr}" =~ $RE_CIDR ]] ||
  ui_die "$(t setup.err.admin_cidr)"

# =============================================================================================
# 4. Repo que va a clonar la máquina
# =============================================================================================

ui_title "$(t setup.repo.title)"

repo_url="${ZS_REPO_URL:-}"
if [[ -z "${repo_url}" ]]; then
  origin_url="$(git remote get-url origin 2>/dev/null || true)"
  [[ -n "${origin_url}" ]] || origin_url="https://github.com/lucbece/zomboid-server.git"

  if [[ "${origin_url}" == https://* ]]; then
    # Se prueba el clonado anónimo: sin config global (para no usar credenciales guardadas)
    # y sin preguntar usuario/password. Si funciona, el repo es público.
    if GIT_TERMINAL_PROMPT=0 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
      git ls-remote "${origin_url}" HEAD >/dev/null 2>&1; then
      repo_url="${origin_url}"
      ui_ok "$(t setup.repo.public)"
    else
      ui_warn "$(t setup.repo.private)"
      # github.com/usuario/repo.git -> git@github.com:usuario/repo.git
      ssh_url="$(echo "${origin_url}" | sed -E 's#^https://([^/]+)/#git@\1:#')"
      ui_hint "$(t setup.repo.private_hint1 "${ssh_url}")"
      ui_hint "$(t setup.repo.private_hint2)"
      repo_url="${ssh_url}"
    fi
  else
    repo_url="${origin_url}"
    ui_ok "$(t setup.repo.ssh)"
  fi
fi

if [[ "${repo_url}" == https://* ]]; then
  usa_deploy_key="$(t setup.repo.key_no)"
else
  usa_deploy_key="$(t setup.repo.key_yes)"
fi
ui_say "$(t setup.repo.summary "${repo_url}" "${usa_deploy_key}")"

repo_branch="$(elegir '' repo_branch "")"
if [[ -z "${repo_branch}" ]]; then
  repo_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
fi
[[ "${repo_branch}" =~ ^[A-Za-z0-9._/-]+$ ]] || repo_branch="main"

bucket_name="$(elegir ZS_BUCKET_NAME bucket_name "zomboid-backups")"

# =============================================================================================
# 5. Contraseñas
# =============================================================================================

ui_title "$(t setup.pass.title)"

printf '%s\n\n' "$(t setup.pass.intro)"

definir_password() {
  local var="$1" clave="$2" etiqueta="$3" actual nueva
  actual="${!var:-}"
  [[ -n "${actual}" ]] || actual="$(tfvar_actual "${clave}")"
  if [[ -z "${actual}" || "${actual}" == *CAMBIAME* ]]; then
    actual="$(generar_password)"
  fi
  nueva="$(preguntar "$(t setup.q.password "${etiqueta}")" "${actual}")"
  password_valida "${nueva}" ||
    ui_die "$(t setup.err.password "${etiqueta}")"
  echo "${nueva}"
}

server_password="$(definir_password ZS_SERVER_PASSWORD server_password "$(t setup.pass.label.server)")"
admin_password="$(definir_password ZS_ADMIN_PASSWORD admin_password "$(t setup.pass.label.admin)")"
rcon_password="$(definir_password ZS_RCON_PASSWORD rcon_password "$(t setup.pass.label.rcon)")"

# =============================================================================================
# 6. Escribir los archivos
# =============================================================================================

ui_title "$(t setup.write.title)"

mkdir -p "$(dirname "${TFVARS}")"

umask 077
cat >"${TFVARS}" <<TFVARS_EOF
# Generado por ./setup.sh el $(date '+%Y-%m-%d %H:%M').
# Tiene contraseñas: está en .gitignore, NUNCA lo subas a GitHub.
# Para cambiar algo: volvé a correr ./setup.sh (o editá acá y corré make deploy).

# --- Cuenta ---------------------------------------------------------------------------------
tenancy_ocid = "${tenancy_ocid}"
region       = "${region}"

# --- Acceso ---------------------------------------------------------------------------------
admin_cidr     = "${admin_cidr}"
ssh_public_key = "${ssh_public_key}"

# --- Repo -----------------------------------------------------------------------------------
repo_url    = "${repo_url}"
repo_branch = "${repo_branch}"

# --- Avisos de gasto ------------------------------------------------------------------------
alert_email = "${alert_email}"
budget_usd  = ${budget_usd}

# --- Tamaño de la máquina -------------------------------------------------------------------
ocpus               = ${ocpus}
memory_gb           = ${memory_gb}
boot_volume_size_gb = 80

# --- Server de juego ------------------------------------------------------------------------
admin_username  = "admin"
admin_password  = "${admin_password}"
rcon_password   = "${rcon_password}"
server_password = "${server_password}"
public_name     = "${public_name}"
cli_lang        = "${zs_lang}"
max_players     = ${max_players}
max_memory      = "${max_memory}"

bucket_name = "${bucket_name}"
TFVARS_EOF
chmod 600 "${TFVARS}"
ui_ok "${TFVARS#"${REPO_DIR}/"}"

cat >"${ENV_FILE}" <<ENV_EOF
# Generado por ./setup.sh el $(date '+%Y-%m-%d %H:%M').
# Tiene contraseñas: está en .gitignore, NUNCA lo subas a GitHub.
#
# Este .env es el de ESTA computadora (sirve para correr el server en local con 'make up').
# El .env de la máquina en la nube lo genera cloud-init a partir de terraform.tfvars.

# --- Cuenta de admin del juego ---
ADMINUSERNAME=admin
ADMINPASSWORD="${admin_password}"

# --- RCON (puerto 27015, solo local) ---
RCONPASSWORD="${rcon_password}"
RCON_PORT=27015

# --- Acceso de los jugadores ---
SERVER_PASSWORD="${server_password}"
PUBLIC_NAME="${public_name}"
MAX_PLAYERS=${max_players}

# --- Puertos del juego ---
GAME_PORT=16261
GAME_UDP_PORT=16262

# --- Memoria de la JVM ---
MIN_MEMORY=2048m
MAX_MEMORY=${max_memory}

# --- Mods ---
MOD_ID_PREFIX=

# --- Red: UPnP solo sirve en una PC de casa; en la nube queda en false ---
UPNP=false

# --- Puente de Discord (opcional) ---
DISCORD_ENABLE=false
DISCORD_TOKEN=
DISCORD_CHAT_CHANNEL=
DISCORD_LOG_CHANNEL=
DISCORD_COMMAND_CHANNEL=

# --- Backups ---
RCLONE_REMOTE=oci
BACKUP_BUCKET=
BACKUP_KEEP_LOCAL_DAYS=3

# --- Apagado por inactividad (todavía sin usar) ---
IDLE_MINUTES=30

# --- CLI ---
ZS_LANG=${zs_lang}
ENV_EOF
chmod 600 "${ENV_FILE}"
ui_ok ".env"

# --- Mods: config/mods.txt es propio de cada partida y no se versiona ---------------------------
MODS_FILE="${REPO_DIR}/config/mods.txt"
if [[ -f "${MODS_FILE}" ]]; then
  mods_n="$(grep -cE '^[[:space:]]*[0-9]+' "${MODS_FILE}" || true)"
  if [[ "${mods_n}" -gt 0 ]]; then
    ui_ok "$(t setup.mods.count "${mods_n}")"
  else
    ui_ok "$(t setup.mods.vanilla)"
  fi
else
  cp "${REPO_DIR}/config/mods.example.txt" "${MODS_FILE}"
  ui_ok "$(t setup.mods.created)"
  ui_hint "$(t setup.mods.hint1)"
  ui_hint "$(t setup.mods.hint2)"
fi

# --- Reglas del sandbox: tambien propias de cada partida, tampoco versionadas -------------------
SANDBOX_FILE="${REPO_DIR}/config/servertest_SandboxVars.lua"
if [[ -f "${SANDBOX_FILE}" ]]; then
  ui_ok "config/servertest_SandboxVars.lua"
else
  cp "${REPO_DIR}/config/servertest_SandboxVars.example.lua" "${SANDBOX_FILE}"
  ui_ok "$(t setup.sandbox.created)"
  ui_hint "$(t setup.sandbox.hint1)"
  ui_hint "$(t setup.sandbox.hint2)"
fi

umask 022

# =============================================================================================
# 7. Qué sigue
# =============================================================================================

if [[ "${mods_n:-0}" -gt 0 ]]; then
  resumen_mods="$(t setup.summary.mods_some "${mods_n}")"
else
  resumen_mods="$(t setup.summary.mods_none)"
fi

printf '%s\n\n' "$(t setup.summary \
  "${public_name}" "${max_players}" "${ocpus}" "${memory_gb}" "${max_memory}" "${region}" \
  "${alert_email}" "${budget_usd}" "${admin_cidr}" "${server_password}" "${resumen_mods}")"
