# zomboid-server

Servidor dedicado de Project Zomboid **Build 42** (rama estable de Steam desde 2026-07-29, versión 42.20.x) para 8-16 jugadores, dockerizado, con config en git y deploy a una VM en la nube.

## Leer primero
- `PLAN.md`: decisiones tomadas, fases y criterios de aceptación. No re-litigar las decisiones de §1.
- `docs/research/`: investigación con fuentes. Consultar antes de buscar en la web:
  - `01-b42-server-install.md`: steamcmd, flags, puertos, heap, rutas, systemd.
  - `02-docker-and-tooling.md`: imágenes Docker, por qué Danixu, backups, IaC existente.
  - `03-cloud-hosting.md`: proveedores, precios (2026-09-03), latencia desde Buenos Aires.
  - `04-server-config-and-mods.md`: claves de `servertest.ini`, SandboxVars, spawn, mods, comandos admin, problemas comunes.
- `docs/runbook.md`: operación en la nube (alta de la cuenta OCI, deploy, backups, wipe, troubleshooting). Es la **referencia avanzada**: el documento principal para el usuario final es `README.md`.
- `README.md`: guía paso a paso para principiantes (Fase 2.5). Si cambia el flujo de deploy, se actualiza acá **y** en el runbook. `README.en.md` es el resumen corto en inglés.

## Hechos fijos
- App ID del server: `380870`. Rama Steam pública = B42; **no** usar `-beta`. B41 = `-beta legacy41`.
- Imagen: `danixu86/project-zomboid-dedicated-server` con `SELF_MANAGED_MODS=1`, pinneada por digest `sha256:a98b0f219f63ad9f08b0658cf77c2c165705ab8d74775fd3db6e50fd6f4961e1` (trae el juego adentro, 42.20.4). Entrypoint auditado en `docs/research/02-docker-and-tooling.md` §7: solo reescribe `RCONPassword` y `UDPPort` con nuestra config.
- Datos del server dentro del contenedor: `/home/steam/Zomboid` (bind mount `./data/zomboid`). Workshop: `/home/steam/pz-dedicated/steamapps/workshop` (bind mount `./data/workshop`).
- Puertos: `16261-16262/udp` juego, `27015/tcp` RCON (solo admin). `8766-8767/udp` opcional.
- Nombre del server: `servertest` (no cambiar; nombra todos los archivos de config).
- `Mods=` = IDs de `mod.info` separados por `;` (load order). `WorkshopItems=` = IDs numéricos separados por `;`. Prefijo `\` por ID: **verificado empíricamente en 42.20.4 el 2026-09-03, es indiferente** (con y sin prefijo el mod carga igual); el repo usa la forma sin prefijo. Detalle en `docs/mods.md`.

## Hechos de la nube (Fase 2: código listo, `tofu apply` pendiente)
- Proveedor **Oracle Cloud, región `sa-saopaulo-1`** (Brazil East / São Paulo). El plan decía Vinhedo; se cambió el 2026-09-03 porque el alta de la cuenta no ofreció esa región.
- **Rutas en la VM**: repo en `/opt/zomboid-server`, datos en `/opt/zomboid-server/data/zomboid`, backups locales en `/opt/zomboid-server/backups`, logs de cron en `/var/log/zomboid/`. Unit systemd en `/etc/systemd/system/zomboid.service` (instalada desde `infra/systemd/`).
- **Usuario de la VM: `pz`** (grupos `docker` y `sudo`, sudo sin password). El `ubuntu` de la imagen de OCI también queda, con la key de metadata.
- El `.env` de la VM lo genera **cloud-init desde `terraform.tfvars`**, no se sincroniza con `make sync` ni se commitea. Las passwords están validadas en el módulo: 8-64 caracteres sin espacios, comillas, backslash ni `$` (el `.env` lo parsean bash y docker compose, que no escapan igual).
- La VM escribe el bucket de backups por **instance principal** (`rclone` con `provider = instance_principal_auth`): no hay ninguna credencial de OCI en el disco.
- **`repo_url` decide todo el flujo del clonado**: si empieza con `https://` (repo público) no se crea `tls_private_key` (`count = 0`), el template no escribe `deploy_key` ni `~/.ssh/config` ni corre `ssh-keyscan`, y `deploy_public_key` sale vacío. Si es SSH (`git@…`), OpenTofu genera el par ed25519 y hay que cargar la pública en GitHub antes del primer boot o cloud-init falla al clonar (`make deploy` lo hace con `gh` si está autenticado). La condición es `local.use_deploy_key` en `modules/oci/main.tf`; el template la recibe como `use_deploy_key` y la usa con `%{ if ~} … %{ endif ~}`.
- Default de `repo_url`: `https://github.com/lucbece/zomboid-server.git` (upstream público).
- La IP pública es un `oci_core_public_ip` **RESERVED** atado a la private IP de la VNIC (`assign_public_ip = false`): sobrevive los stop/start de la Fase 3.

## Camino feliz del usuario final (Fase 2.5)
- `./setup.sh` (asistente, re-ejecutable, modo `--no-preguntar` con variables `ZS_*` para pruebas/CI) → `make deploy` → `make doctor` / `make destroy-all`.
- Scripts nuevos: `setup.sh` (raíz), `scripts/{deploy,doctor,destroy-all,render-cloud-init}.sh`, `scripts/lib/{ui,palabras}.sh`.
- `scripts/lib/ui.sh` es el estilo común de salida: `ui_ok` / `ui_warn` / `ui_miss` + `ui_hint` con **la acción a tomar**. Todo mensaje al usuario final va en castellano simple y dice qué hacer después.
- `scripts/lib/oci-instance.sh` expone `tofu_output <nombre> [regex]`: sin state, `tofu output` escribe un warning en **stdout** y sale con 0, así que siempre hay que filtrar (`TF_RE_OCID`, `TF_RE_IP`, `TF_RE_NOMBRE`).
- Passwords: se generan como `tres-palabras-1234` desde `scripts/lib/palabras.sh` (310 palabras ASCII). Tienen que cumplir la validación del módulo: `^[A-Za-z0-9._@#%^&*()+=:,/-]{8,64}$`.

## Cómo validar sin credenciales (todo esto pasa hoy)
- OpenTofu está en `~/.local/bin/tofu` (v1.12.6, checksum verificado; no hay sudo en `lucpc`).
  ```bash
  tofu -chdir=infra/terraform/envs/prod init      # descarga oracle/oci y hashicorp/tls
  tofu -chdir=infra/terraform/envs/prod validate  # -> Success! The configuration is valid.
  tofu fmt -check -recursive infra/terraform
  ```
  **No correr `apply`**: necesita `~/.oci/config` y crea recursos pagos. `plan -var-file=…` sí sirve para verificar las `validation` de las variables: falla recién en el provider (`open ~/.oci/config: no such file`), después de validarlas todas.
- `infra/cloud-init.yaml` es un **template de `templatefile()`**: `${...}` lo reemplaza Tofu, un `$` literal se escribe `$$`. Renderizarlo con `scripts/render-cloud-init.sh` y validar **los dos modos**:
  ```bash
  scripts/render-cloud-init.sh https /tmp/ci-https.yaml
  scripts/render-cloud-init.sh ssh   /tmp/ci-ssh.yaml
  docker run --rm -v /tmp:/mnt ubuntu:24.04 bash -c \
    'apt-get update -qq && apt-get install -y -qq cloud-init >/dev/null &&
     cloud-init schema --config-file /mnt/ci-https.yaml &&
     cloud-init schema --config-file /mnt/ci-ssh.yaml'
  ```
  (`cloud-init` no está en `lucpc` y no hay paquete pip oficial.)
- `.terraform.lock.hcl` **sí** se commitea (pin de providers). `terraform.tfvars`, `*.tfstate*` y `.terraform/` no.

## Reglas de trabajo
- **El repo es público** (o va a serlo). Todo lo que se commitea lo lee cualquiera: nada de IPs reales, OCIDs, mails, passwords ni claves privadas, ni siquiera de ejemplo en comentarios. Usar `203.0.113.10` (TEST-NET-3), `usuario@pc`, `TU_IP_LAN`, `ocid1.tenancy.oc1..aaaaaaaaCAMBIAME`.
- **Nunca** commitear `.env`, `terraform.tfvars`, `*.tfstate`, `backups/` ni `config/servertest.ini` renderizado (solo el `.tpl`).
- Antes de cerrar una fase, correr gitleaks sobre **todo el historial**: `docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest detect --source /repo --no-banner`.
- **Nunca** parar el server con `docker stop`/`kill` directo: siempre RCON `save` + `quit` (`scripts/stop.sh`).
- La fuente de verdad de la config es `config/`. No editar a mano archivos dentro de `data/`.
- Los scripts son bash con `set -euo pipefail` y pasan `shellcheck` (en `lucpc` no está instalado: usar `docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x setup.sh scripts/*.sh scripts/lib/*.sh`). En esta shell Docker necesita `sg docker -c "..."`.
- Comentarios del código y del `.md` técnico: castellano sin tildes en los scripts (por consistencia con lo existente); los mensajes que ve el usuario final sí llevan tildes.
- `.env` lo parsean bash (`source`) y `docker compose`, que no escapan igual: valores con espacios entre comillas y un backslash literal solo como `"\\"`.
- No pushear ni crear PRs sin pedido explícito. Sin atribución de IA en commits.
- **El server local está apagado y no se levanta** (`lucpc` tiene pocos recursos): la validación end-to-end se hace en la nube. Docker solo para shellcheck, hadolint y validaciones.
- Si pzwiki devuelve 403, usar `https://r.jina.ai/https://pzwiki.net/wiki/<Pagina>`.
- Al terminar una fase, actualizar `PLAN.md` (marcar tareas hechas), el `README.md` y `docs/runbook.md`.
- El CI (`.github/workflows/ci.yml`) corre shellcheck, `tofu fmt`/`validate`, `cloud-init schema` en los dos modos y gitleaks. Si algo se rompe en local, se rompe en el CI.
