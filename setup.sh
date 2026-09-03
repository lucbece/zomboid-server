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
#   ZS_PUBLIC_NAME  ZS_MAX_PLAYERS  ZS_ALERT_EMAIL  ZS_BUDGET_USD  ZS_REGION
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
      sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *) ui_die "opción desconocida: ${arg} (probá ./setup.sh --ayuda)" ;;
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
  read -r -p "  ${1:-Cuando termines apretá Enter para seguir} " _ || true
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
# 0. Bienvenida
# =============================================================================================

cat <<'BIENVENIDA'

  ============================================================
   Servidor de Project Zomboid: asistente de configuración
  ============================================================

  Esto NO crea nada en la nube todavía y NO gasta plata. Solo prepara los archivos de
  configuración. Después, cuando quieras, corrés  make deploy  y ahí sí se crea el servidor.

  Vas a necesitar:
    - una cuenta de Oracle Cloud ya creada y con tarjeta cargada (el README explica cómo)
    - un mail donde recibir los avisos de gasto
    - unos 5 minutos

  Si algo no lo entendés, apretá Enter para aceptar el valor entre corchetes: son valores
  razonables para empezar.

BIENVENIDA

pausa "Enter para empezar."

# =============================================================================================
# 1. Herramientas
# =============================================================================================

ui_title "1. Herramientas en esta computadora"

faltan_bloqueantes=0

for cmd in git curl make ssh rsync; do
  if command -v "${cmd}" >/dev/null 2>&1; then
    ui_ok "${cmd}"
  else
    ui_miss "${cmd}"
    ui_hint "Instalalo con:  sudo apt install ${cmd}   (o el gestor de paquetes de tu sistema)"
    faltan_bloqueantes=1
  fi
done

if ((BASH_VERSINFO[0] >= 4)); then
  ui_ok "bash ${BASH_VERSION%%(*}"
else
  ui_miss "bash ${BASH_VERSION%%(*}: hace falta bash 4 o más nuevo"
  ui_hint "En macOS:  brew install bash  y volvé a correr ./setup.sh con el bash nuevo"
  faltan_bloqueantes=1
fi

[[ "${faltan_bloqueantes}" -eq 0 ]] || ui_die "instalá lo que falta y volvé a correr ./setup.sh"

# --- OpenTofu ---------------------------------------------------------------------------------
# Es el programa que crea la máquina en la nube leyendo la carpeta infra/.
export PATH="${HOME}/.local/bin:${PATH}"

instalar_tofu() {
  local tmp
  command -v unzip >/dev/null 2>&1 || {
    ui_hint "hace falta 'unzip':  sudo apt install unzip"
    return 1
  }
  tmp="$(mktemp -d)"
  ui_say "  Bajando OpenTofu ${TOFU_VERSION}..."
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
  ui_ok "OpenTofu $(tofu version | head -1 | awk '{print $2}')"
else
  ui_miss "OpenTofu: es el programa que crea la máquina en la nube"
  if [[ "${PREGUNTAR}" -eq 1 ]] && ui_confirm "Lo instalo en ~/.local/bin (no hace falta sudo)?" s; then
    if instalar_tofu; then
      ui_ok "OpenTofu instalado en ~/.local/bin/tofu"
    else
      ui_die "no se pudo instalar OpenTofu. Instrucciones manuales: docs/runbook.md §1.5"
    fi
  else
    ui_hint "Instrucciones manuales: docs/runbook.md §1.5"
    ui_die "sin OpenTofu no se puede desplegar"
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
  ui_ok "clave SSH tomada de ZS_SSH_PUBLIC_KEY"
elif ssh_pub_file="$(elegir_clave_ssh)"; then
  ui_ok "clave SSH: ${ssh_pub_file}"
else
  ui_miss "no tenés una clave SSH (es lo que te deja entrar a la máquina de la nube)"
  if [[ "${PREGUNTAR}" -eq 1 ]] && ui_confirm "La creo ahora? (no te va a pedir contraseña)" s; then
    ssh-keygen -t ed25519 -N '' -C "zomboid-server" -f "${HOME}/.ssh/id_ed25519"
    ssh_pub_file="${HOME}/.ssh/id_ed25519.pub"
    ui_ok "clave creada en ${ssh_pub_file}"
  else
    ui_die "hace falta una clave SSH. Creala con:  ssh-keygen -t ed25519"
  fi
fi

ssh_public_key="${ZS_SSH_PUBLIC_KEY:-}"
if [[ -z "${ssh_public_key}" && -n "${ssh_pub_file}" ]]; then
  ssh_public_key="$(tr -d '\n' <"${ssh_pub_file}")"
fi
[[ "${ssh_public_key}" =~ $RE_SSH_PUB ]] ||
  ui_die "la clave pública SSH no tiene la forma esperada (tiene que empezar con ssh-ed25519)"

# --- gh (opcional) ----------------------------------------------------------------------------
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  ui_ok "GitHub CLI conectado (se usa solo si tu repo es privado)"
else
  ui_warn "GitHub CLI (gh) no está o no está conectado: no pasa nada, es opcional"
fi

# =============================================================================================
# 2. Cuenta de Oracle Cloud
# =============================================================================================

ui_title "2. Cuenta de Oracle Cloud"

instalar_oci_cli() {
  command -v python3 >/dev/null 2>&1 || {
    ui_hint "hace falta python3"
    return 1
  }
  python3 -m venv "${HOME}/.venvs/oci"
  "${HOME}/.venvs/oci/bin/pip" install --quiet --upgrade pip oci-cli
  mkdir -p "${HOME}/.local/bin"
  ln -sf "${HOME}/.venvs/oci/bin/oci" "${HOME}/.local/bin/oci"
}

if [[ -n "${ZS_SKIP_OCI:-}" ]]; then
  ui_warn "ZS_SKIP_OCI=1: me salteo la verificación de la cuenta de Oracle Cloud"
else
  if [[ ! -f "${OCI_CONFIG}" ]]; then
    cat <<'APIKEY'

  Falta conectar tu cuenta de Oracle Cloud con esta computadora. Es un archivo con una clave
  que Oracle te genera. Hacelo así (5 minutos):

   1. Entrá a https://cloud.oracle.com e iniciá sesión.
   2. Arriba a la derecha, ícono de la persona -> "My profile".
   3. En el menú de la izquierda, "API keys" -> botón "Add API key".
   4. Dejá marcado "Generate API key pair" y apretá "Download private key".
      Se te baja un archivo .pem: guardalo, es tu llave.
   5. Apretá "Add". Oracle te muestra un cuadro de texto con varias líneas
      (user=..., fingerprint=..., tenancy=..., region=...). Copialo entero.
   6. En esta computadora, ejecutá en otra terminal:

        mkdir -p ~/.oci && chmod 700 ~/.oci
        mv ~/Descargas/*.pem ~/.oci/oci_api_key.pem     (o ~/Downloads)
        chmod 600 ~/.oci/oci_api_key.pem
        nano ~/.oci/config

      Pegá el cuadro que copiaste y agregá al final la línea:

        key_file=/home/TU_USUARIO/.oci/oci_api_key.pem

      Guardá con Ctrl+O, Enter, Ctrl+X. Después:

        chmod 600 ~/.oci/config

APIKEY
    pausa "Cuando lo tengas listo, apretá Enter."
  fi

  if [[ -f "${OCI_CONFIG}" ]]; then
    ui_ok "archivo de la cuenta: ${OCI_CONFIG}"
    key_file="$(oci_config_valor key_file)"
    if [[ -n "${key_file}" && -f "${key_file/#\~/${HOME}}" ]]; then
      ui_ok "clave privada de la API: ${key_file}"
    else
      ui_warn "la línea key_file= de ${OCI_CONFIG} apunta a un archivo que no existe"
      ui_hint "Corregila con la ruta completa del .pem que bajaste de Oracle."
    fi
  else
    ui_warn "sigue sin haber ${OCI_CONFIG}: podés seguir, pero 'make deploy' va a fallar"
  fi

  if command -v oci >/dev/null 2>&1; then
    ui_ok "CLI oci instalado"
  else
    ui_warn "el programa 'oci' no está (sirve para prender y apagar el server, y para chequeos)"
    if [[ "${PREGUNTAR}" -eq 1 ]] && ui_confirm "Lo instalo en ~/.venvs/oci (sin sudo)?" s; then
      if instalar_oci_cli; then
        ui_ok "oci instalado (~/.local/bin/oci)"
      else
        ui_warn "no se pudo instalar el CLI oci; seguimos sin él"
      fi
    fi
  fi

  if command -v oci >/dev/null 2>&1 && [[ -f "${OCI_CONFIG}" ]]; then
    if oci iam region list --query 'data[0]' >/dev/null 2>&1; then
      ui_ok "la cuenta de Oracle Cloud responde: la clave está bien configurada"
    else
      ui_warn "Oracle no acepta la clave todavía"
      ui_hint "Revisá user=, fingerprint=, tenancy= y key_file= en ${OCI_CONFIG}."
      ui_hint "Para ver el error completo:  oci iam region list"
    fi
  fi
fi

# =============================================================================================
# 3. Preguntas
# =============================================================================================

ui_title "3. Cómo querés tu server"

public_name="$(preguntar "Nombre del server (lo ven tus amigos)" \
  "$(elegir ZS_PUBLIC_NAME public_name "Mi server de Zomboid")")"
[[ "${public_name}" =~ $RE_NOMBRE ]] ||
  ui_die "el nombre no puede tener comillas dobles, barra invertida, signo pesos ni acento grave"

max_players="$(preguntar "Cuántos jugadores como máximo" \
  "$(elegir ZS_MAX_PLAYERS max_players 8)")"
[[ "${max_players}" =~ ^[0-9]{1,3}$ ]] || ui_die "la cantidad de jugadores tiene que ser un número"

# Memoria de la JVM: con 16 GB de RAM, 8g alcanza hasta 8 jugadores y 12g para más.
if ((max_players <= 8)); then max_memory="8g"; else max_memory="12g"; fi

alert_email="$(preguntar "Mail donde recibir los avisos de gasto de Oracle" \
  "$(elegir ZS_ALERT_EMAIL alert_email "")")"
[[ "${alert_email}" == *@*.* ]] || ui_die "hace falta un mail válido para las alertas de gasto"

budget_usd="$(preguntar "Aviso de gasto cuando el mes pase de (USD)" \
  "$(elegir ZS_BUDGET_USD budget_usd 25)")"
[[ "${budget_usd}" =~ ^[0-9]+$ ]] || ui_die "el presupuesto tiene que ser un número entero"

# --- Región -----------------------------------------------------------------------------------
REGIONES=(
  "sa-saopaulo-1|São Paulo, Brasil        | ~30 ms desde Argentina  (recomendada acá)"
  "sa-vinhedo-1|Vinhedo, Brasil          | ~30 ms desde Argentina"
  "sa-santiago-1|Santiago, Chile          | ~25-35 ms desde Argentina"
  "us-ashburn-1|Ashburn, EEUU (costa E)  | ~140 ms desde Argentina, ~20 ms desde EEUU este"
  "us-phoenix-1|Phoenix, EEUU (oeste)    | ~180 ms desde Argentina, ~20 ms desde EEUU oeste"
  "eu-frankfurt-1|Frankfurt, Alemania      | ~230 ms desde Argentina, ~20 ms desde Europa"
  "eu-madrid-1|Madrid, España           | ~210 ms desde Argentina, ~20 ms desde España"
  "uk-london-1|Londres, Reino Unido     | ~220 ms desde Argentina, ~15 ms desde UK"
)

region_default="$(elegir ZS_REGION region "$(oci_config_valor region)")"
[[ -n "${region_default}" ]] || region_default="sa-saopaulo-1"

if [[ "${PREGUNTAR}" -eq 1 ]]; then
  echo
  echo "  Región (dónde va a estar la máquina). Elegí la más cercana a donde viven los jugadores:"
  echo
  i=1
  for linea in "${REGIONES[@]}"; do
    printf '    %d) %-16s %s\n' "${i}" "${linea%%|*}" "${linea#*|}"
    i=$((i + 1))
  done
  echo
  echo "  IMPORTANTE: tiene que ser la MISMA región que elegiste al crear la cuenta de Oracle"
  echo "  (la \"home region\"). Si no coincide, el deploy falla. Si no te acordás, es la que"
  echo "  aparece arriba a la derecha en la consola de Oracle."
  echo
  eleccion="$(preguntar "Número de región, o escribí el código a mano" "${region_default}")"
  if [[ "${eleccion}" =~ ^[0-9]+$ ]] && ((eleccion >= 1 && eleccion <= ${#REGIONES[@]})); then
    linea="${REGIONES[$((eleccion - 1))]}"
    region="${linea%%|*}"
  else
    region="${eleccion}"
  fi
else
  region="${region_default}"
fi
[[ "${region}" =~ ^[a-z0-9-]+$ ]] || ui_die "el código de región no parece válido: ${region}"

if [[ -n "$(oci_config_valor region)" && "$(oci_config_valor region)" != "${region}" ]]; then
  ui_warn "elegiste ${region} pero tu cuenta dice $(oci_config_valor region)"
  ui_hint "Si el deploy falla con 'NotAuthorizedOrNotFound', usá la de tu cuenta."
fi

# --- Tenancy y acceso --------------------------------------------------------------------------
tenancy_default="$(elegir ZS_TENANCY_OCID tenancy_ocid "$(oci_config_valor tenancy)")"
tenancy_ocid="$(preguntar "ID de tu cuenta de Oracle (la línea 'tenancy=' de ~/.oci/config)" "${tenancy_default}")"
[[ "${tenancy_ocid}" == ocid1.tenancy.* ]] ||
  ui_die "el ID de la cuenta tiene que empezar con ocid1.tenancy. Sacalo de ${OCI_CONFIG}"

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
[[ -n "${admin_cidr_default}" ]] || ui_die "no pude averiguar tu IP pública. Ponela a mano: curl https://ifconfig.me"

echo
echo "  Tu IP de internet es la única desde la que vas a poder administrar el server."
echo "  (Tus amigos entran igual desde cualquier lado: esto es solo para administrar.)"
echo "  Si tu conexión cambia de IP, más adelante corrés ./setup.sh y make deploy de nuevo."
admin_cidr="$(preguntar "Tu IP de admin" "${admin_cidr_default}")"
[[ "${admin_cidr}" =~ $RE_CIDR ]] ||
  ui_die "la IP de admin tiene que tener la forma 1.2.3.4/32"

# =============================================================================================
# 4. Repo que va a clonar la máquina
# =============================================================================================

ui_title "4. De dónde baja la configuración la máquina"

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
      ui_ok "tu repo es público: la máquina lo baja sola, no hay nada más que hacer"
    else
      ui_warn "tu repo es privado (o no existe todavía)"
      # github.com/usuario/repo.git -> git@github.com:usuario/repo.git
      ssh_url="$(echo "${origin_url}" | sed -E 's#^https://([^/]+)/#git@\1:#')"
      ui_hint "Voy a usar ${ssh_url} y una llave de solo lectura que se carga en GitHub."
      ui_hint "Si preferís evitar ese paso, hacé el repo público en GitHub -> Settings -> General."
      repo_url="${ssh_url}"
    fi
  else
    repo_url="${origin_url}"
    ui_ok "tu repo se clona por SSH: se va a usar una llave de solo lectura"
  fi
fi

if [[ "${repo_url}" == https://* ]]; then
  usa_deploy_key="no"
else
  usa_deploy_key="sí"
fi
ui_say "  Repo: ${repo_url}   (llave de solo lectura: ${usa_deploy_key})"

repo_branch="$(elegir '' repo_branch "")"
if [[ -z "${repo_branch}" ]]; then
  repo_branch="$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)"
fi
[[ "${repo_branch}" =~ ^[A-Za-z0-9._/-]+$ ]] || repo_branch="main"

bucket_name="$(elegir ZS_BUCKET_NAME bucket_name "zomboid-backups")"

# =============================================================================================
# 5. Contraseñas
# =============================================================================================

ui_title "5. Contraseñas"

cat <<'PASS'
  Se generan tres contraseñas distintas. No hace falta que las memorices: quedan guardadas
  en los archivos de configuración y 'make deploy' te va a mostrar la que le tenés que pasar
  a tus amigos.

    - del server: la que ponen tus amigos para entrar
    - de admin:   tu usuario administrador dentro del juego
    - de RCON:    la usa el programa para hablar con el server, no la escribe nadie

PASS

definir_password() {
  local var="$1" clave="$2" etiqueta="$3" actual nueva
  actual="${!var:-}"
  [[ -n "${actual}" ]] || actual="$(tfvar_actual "${clave}")"
  if [[ -z "${actual}" || "${actual}" == *CAMBIAME* ]]; then
    actual="$(generar_password)"
  fi
  nueva="$(preguntar "Contraseña ${etiqueta} (Enter acepta la sugerida)" "${actual}")"
  password_valida "${nueva}" ||
    ui_die "la contraseña ${etiqueta} tiene que tener entre 8 y 64 caracteres, sin espacios, comillas, barra invertida ni signo pesos"
  echo "${nueva}"
}

server_password="$(definir_password ZS_SERVER_PASSWORD server_password "del server")"
admin_password="$(definir_password ZS_ADMIN_PASSWORD admin_password "de admin")"
rcon_password="$(definir_password ZS_RCON_PASSWORD rcon_password "de RCON")"

# =============================================================================================
# 6. Escribir los archivos
# =============================================================================================

ui_title "6. Guardando la configuración"

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
ocpus               = 4
memory_gb           = 16
boot_volume_size_gb = 80

# --- Server de juego ------------------------------------------------------------------------
admin_username  = "admin"
admin_password  = "${admin_password}"
rcon_password   = "${rcon_password}"
server_password = "${server_password}"
public_name     = "${public_name}"
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
ENV_EOF
chmod 600 "${ENV_FILE}"
ui_ok ".env"

umask 022

# =============================================================================================
# 7. Qué sigue
# =============================================================================================

cat <<RESUMEN

  ============================================================
   Listo. Así te quedó configurado:
  ============================================================

    Nombre del server ...... ${public_name}
    Jugadores máximo ....... ${max_players}
    Región ................. ${region}
    Avisos de gasto ........ ${alert_email} (a partir de ${budget_usd} USD/mes)
    Administración desde ... ${admin_cidr}
    Contraseña del server .. ${server_password}

  Ahora:

    make doctor     revisa que esté todo listo (opcional, 10 segundos)
    make deploy     crea el servidor en la nube (tarda 20-40 minutos la primera vez)

  A partir de acá SÍ se empieza a gastar plata: alrededor de 90 USD/mes si dejás la máquina
  prendida todo el tiempo. Para dejar de pagar:  make destroy-all

RESUMEN
