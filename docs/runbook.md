# Runbook: servidor de Project Zomboid en Oracle Cloud

Operación del server en la nube: qué hay que hacer a mano una sola vez, cómo se despliega, cómo se
opera día a día y qué hacer cuando algo se rompe.

> **Este documento es la referencia avanzada.** Si es la primera vez, la guía paso a paso está en
> [`README.md`](../README.md): tres comandos (`./setup.sh`, `make deploy`) y todo lo demás
> explicado sin jerga. Acá está el detalle de qué hace cada cosa por debajo y cómo arreglarla a
> mano cuando el camino automático no alcanza.

Decisiones de fondo (proveedor, región, on-demand, sin dominio): `PLAN.md` §1 y §4.

- **Proveedor**: Oracle Cloud Infrastructure, región **Brazil East / São Paulo**
  (`sa-saopaulo-1`), ~30 ms desde Buenos Aires. El plan original apuntaba a Vinhedo
  (`sa-vinhedo-1`); se cambió el 2026-09-03 porque el alta de la cuenta no ofreció esa región.
  Misma latencia y mismo precio de lista.
- **VM**: `VM.Standard.E5.Flex`, 4 OCPU / 16 GB, boot volume 80 GB, Ubuntu 24.04 LTS.
- **Usuario en la VM**: `pz`. El repo vive en `/opt/zomboid-server`, los datos en
  `/opt/zomboid-server/data/zomboid`, los backups locales en `/opt/zomboid-server/backups`.
- **IP**: pública **reservada**, no cambia entre stop y start. Los amigos guardan `IP:16261`.

---

## 1. Prerrequisitos manuales (una sola vez)

Nada de esto lo puede hacer OpenTofu: son pasos de cuenta.

### 1.1 Crear la cuenta de OCI

> **Hecho el 2026-09-03**: la cuenta existe con home region `sa-saopaulo-1`. Este paso queda
> documentado para poder rehacerlo.

1. Ir a https://www.oracle.com/cloud/free/ y crear la cuenta.
2. **La home region tiene que ser Brazil East (São Paulo) — `sa-saopaulo-1`.** Se elige en el
   formulario de alta y **no se puede cambiar después**. Si se elige mal, hay que abrir otra cuenta.
3. Verificar mail, cargar tarjeta (el alta hace un hold de ~1 USD que se devuelve).

### 1.2 Upgrade a Pay As You Go

Las cuentas Free Tier no pueden crear shapes `E5.Flex` pagos: el `tofu apply` falla con
`LimitExceeded` o `NotAuthorizedOrNotFound`.

Consola → menú de la cuenta (arriba a la derecha) → **Upgrade to Paid** / *Billing & Cost
Management* → *Upgrade and Payment*. Tarda unos minutos en propagarse.

Después del upgrade, confirmar en **Governance & Administration → Limits, Quotas and Usage** que hay
service limit disponible para `VM.Standard.E5.Flex` en `sa-saopaulo-1` (buscar el límite
"Cores for Standard.E5.Flex"). Si está en 0, hay que pedir un aumento (es gratis, tarda horas).

### 1.3 Crear la API key y `~/.oci/config`

1. Consola → ícono de perfil → **My profile** → **API keys** → **Add API key**.
2. Elegir **Generate API key pair**, bajar la private key y hacer **Add**.
3. La consola muestra un bloque de configuración. Copiarlo:

```bash
mkdir -p ~/.oci
chmod 700 ~/.oci
mv ~/Descargas/*.pem ~/.oci/oci_api_key.pem
chmod 600 ~/.oci/oci_api_key.pem
$EDITOR ~/.oci/config
```

`~/.oci/config` queda así (los valores salen del bloque que muestra la consola):

```ini
[DEFAULT]
user=ocid1.user.oc1..aaaa...
fingerprint=aa:bb:cc:...
tenancy=ocid1.tenancy.oc1..aaaa...
region=sa-saopaulo-1
key_file=/home/luc/.oci/oci_api_key.pem
```

```bash
chmod 600 ~/.oci/config
```

El `tenancy=` de ese archivo es el valor de `tenancy_ocid` en `terraform.tfvars`.

### 1.4 Instalar el CLI `oci` (opcional para la Fase 2, necesario para la 3)

`./setup.sh` ofrece instalarlo solo. A mano, sin `sudo`, en un venv:

```bash
python3 -m venv ~/.venvs/oci
~/.venvs/oci/bin/pip install --upgrade pip oci-cli
ln -sf ~/.venvs/oci/bin/oci ~/.local/bin/oci
oci iam region list --output table   # verifica que la API key anda
```

### 1.5 Instalar OpenTofu

`./setup.sh` lo instala solo en `~/.local/bin/tofu` (v1.12.6, con verificación de checksum). A mano:

```bash
V=1.12.6
cd "$(mktemp -d)"
curl -sSLO "https://github.com/opentofu/opentofu/releases/download/v${V}/tofu_${V}_linux_amd64.zip"
curl -sSLO "https://github.com/opentofu/opentofu/releases/download/v${V}/tofu_${V}_SHA256SUMS"
sha256sum -c --ignore-missing "tofu_${V}_SHA256SUMS"
unzip -o "tofu_${V}_linux_amd64.zip" tofu
install -m 755 tofu ~/.local/bin/tofu
tofu version
```

### 1.6 Repo que clona la VM (`repo_url`)

cloud-init clona un repo dentro de la VM. Hay tres escenarios y `./setup.sh` elige el correcto
solo, probando `git ls-remote` sin credenciales (`GIT_CONFIG_GLOBAL=/dev/null` para no usar el
credential helper del usuario):

| `repo_url` | Qué hace el módulo | Paso manual |
|---|---|---|
| `https://github.com/usuario/repo.git` (repo **público**) | clon anónimo; **no** genera `tls_private_key`, no escribe `deploy_key` ni `~/.ssh/config` ni corre `ssh-keyscan` | ninguno |
| `git@github.com:usuario/repo.git` (repo **privado**) | genera un par ed25519 y lo inyecta como deploy key | cargar la pública en GitHub (§1.7) |
| default (sin fork) | clona el upstream público `https://github.com/lucbece/zomboid-server.git` | ninguno; la config propia se manda con `make sync` |

Quien quiera versionar su propia config:

```bash
gh repo create USUARIO/zomboid-server --public --source=. --remote=origin
git push -u origin main
```

(o hacer un fork desde la web y `git remote set-url origin https://github.com/USUARIO/zomboid-server.git`)

La condición vive en `local.use_deploy_key` de `infra/terraform/modules/oci/main.tf`
(`!startswith(lower(trimspace(var.repo_url)), "https://")`) y el template la recibe como
`use_deploy_key`.

### 1.7 Cargar la deploy key (solo con repo privado)

OpenTofu genera un par ed25519 y expone la pública como output `deploy_public_key` (vacío si el
repo es público). Hay que cargarla en **GitHub → el repo → Settings → Deploy keys → Add deploy
key**, pegando la clave y **sin marcar "Allow write access"**.

**Orden importante**: el primer `tofu apply` crea la VM y cloud-init intenta clonar el repo apenas
arranca. Si la deploy key no está cargada todavía, el clon falla y hay que rehacer el boot.
`make deploy` (§2) resuelve el orden solo.


### 1.8 Averiguar la IP pública del admin

```bash
curl -s https://ifconfig.me
```

Ese valor con `/32` va en `admin_cidr`. Es el único origen desde el que se puede entrar por SSH y
por RCON. **Si tenés IP dinámica, va a cambiar**: cuando el SSH deje de andar, actualizar
`admin_cidr` en `terraform.tfvars` y correr `make infra-apply` (no recrea la VM, solo la regla).

---

## 2. Primer deploy

### El camino corto

```bash
./setup.sh       # escribe terraform.tfvars y .env (ver §2.1)
make doctor      # revisión previa: OK / AVISO / FALTA con la acción de cada cosa
make deploy      # init -> deploy key si hace falta -> apply -> esperar SSH -> esperar el juego
```

`scripts/deploy.sh` hace los siete pasos en orden y es idempotente: si ya está todo creado, no
cambia nada y vuelve a imprimir el bloque con IP, puerto y `server_password`. Opciones:

- `make deploy YES=1` — sin la confirmación del plan.
- `make deploy DRY_RUN=1` — imprime los pasos sin ejecutar nada (útil para revisar el flujo).
- `ESPERA_SSH_SEG` / `ESPERA_JUEGO_SEG` — timeouts (default 600 s y 1800 s).

`make doctor` (`scripts/doctor.sh`) chequea: bash ≥ 4, `git`/`curl`/`make`/`ssh`/`rsync`, tofu,
clave SSH, `gh` (opcional), `~/.oci/config` con perfil `[DEFAULT]` y `key_file` existente, una
llamada real a la API (`oci iam region-subscription list`), `terraform.tfvars` completo y con
permisos 600, `.env`, alcanzabilidad de `repo_url`, y —si ya hay state— el estado de la instancia
(`oci compute instance get`) y el último backup en el bucket (`oci os object list`). Con `-q`
imprime solo los problemas y devuelve ≠ 0 si falta algo bloqueante; así lo usa `deploy.sh`.

### El camino largo (a mano)

```bash
cd infra/terraform/envs/prod
cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars     # tenancy_ocid, admin_cidr, ssh_public_key, alert_email, passwords
```

Las tres passwords (`admin_password`, `rcon_password`, `server_password`) tienen que tener 8-64
caracteres alfanuméricos o de puntuación simple: sin espacios, comillas, backslash ni `$`. El `.env`
de la VM lo parsean dos cosas distintas (bash y docker compose) que no escapan igual.

Después, desde la raíz del repo:

```bash
make infra-init     # descarga los providers (oracle/oci ~> 7.29, hashicorp/tls ~> 4.1)
make infra-plan     # revisar: ~20 recursos
```

**Con `repo_url` HTTPS (repo público) no hay deploy key**: alcanza con `make infra-apply`.

**Con `repo_url` SSH (repo privado)**, la secuencia para no pelearse con el orden:

```bash
# 1. Crear solo la deploy key, y sacar la pública.
tofu apply -target=module.zomboid.tls_private_key.deploy
tofu output -raw deploy_public_key
# Atajo con GitHub CLI (si está autenticado), en vez de pegarla a mano en la web:
tofu output -raw deploy_public_key > /tmp/zomboid-deploy.pub && gh repo deploy-key add /tmp/zomboid-deploy.pub --title zomboid-vm -R USUARIO/zomboid-server && rm /tmp/zomboid-deploy.pub
# 2. Pegarla en GitHub -> Settings -> Deploy keys (read-only).
# 3. Ahora sí, el resto.
make infra-apply
```

Esto es exactamente lo que hace el paso 3 de `make deploy`.

El apply tarda 2-4 minutos. Al terminar:

```bash
tofu output
# public_ip        = "150.230.x.y"
# game_address     = "150.230.x.y:16261"
# ssh_command      = "ssh pz@150.230.x.y"
# bucket_name      = "zomboid-backups"
# bucket_namespace = "grxxxxxxxx"
```

Dentro de la VM, cloud-init tarda otros **8-15 minutos** (apt upgrade + Docker + el pull de la
imagen de 10.4 GB). Seguirlo:

```bash
ssh pz@$(tofu -chdir=infra/terraform/envs/prod output -raw public_ip)
sudo cloud-init status --wait
sudo tail -f /var/log/cloud-init-output.log
cd /opt/zomboid-server && make logs        # el log del juego (SERVER STARTED) está en Docker, no en journalctl
cd /opt/zomboid-server && make logs     # listo cuando aparece '*** SERVER STARTED ****'
```

Desde la PC del admin, sin entrar a la VM:

```bash
make remote-status
```

### Alta de la partida de prueba

El primer deploy va con **partida limpia y sin mods** (`config/mods.txt` con todo comentado) y
sandbox por defecto, como decidió el usuario en `PLAN.md` ("Cambio de enfoque"). Se valida con un
amigo, se mide ping y RAM, y recién después se hace el wipe (§8).

---

## 3. Cómo se conecta un amigo

Necesitan: Project Zomboid **Build 42** (rama estable de Steam, sin beta), la IP y la
`server_password`.

1. Menú principal → **Join**.
2. Pestaña **Favorites** → **Add server**.
3. Completar:
   - **Name**: lo que quieran.
   - **IP**: la del output `public_ip`.
   - **Port**: `16261`.
   - **Account username / password**: los eligen ellos, se crean solos la primera vez
     (`Open=true`).
   - **Server password**: el valor de `server_password`.
4. **Save** → **Join**.

El server tiene `Public=false`: no aparece en el server browser, hay que agregarlo a mano.

Darle admin a alguien (desde la PC del admin):

```bash
make remote-rcon CMD='setaccesslevel "pepe" admin'
```

---

## 4. Operación diaria

Todo desde la PC del admin. La IP la resuelve solo leyendo `tofu output`; se puede forzar con
`VM_IP=1.2.3.4`.

| Comando | Qué hace |
|---|---|
| `make remote-status` | Contenedor + jugadores conectados |
| `make remote-logs` | Sigue el log del server |
| `make remote-rcon CMD=players` | Cualquier comando de admin por RCON |
| `make remote-restart` | Apagado limpio + re-render + arranque (aplica cambios de config/mods) |
| `make remote-down` | Apaga el server (la VM sigue prendida) |
| `make remote-up` | Lo vuelve a levantar |
| `make remote-backup` | Fuerza un backup y lo sube al bucket |
| `make sync` | rsync de `config/`, `scripts/`, `Makefile`, `docker-compose.yml` a la VM |
| `make sync RESTART=1` | Lo mismo + `remote-restart` |
| `make doctor` | Revisión de prerrequisitos, estado de la VM y último backup |
| `make deploy` | Aplica cambios de infraestructura y espera a que el juego vuelva |
| `make destroy-all` | Backup final + `tofu destroy` (§8.1) |

**`make sync` no sincroniza `.env` ni `data/`**: el `.env` de la VM lo genera cloud-init desde
`terraform.tfvars` y los datos son de la VM.

Hay dos formas de llevar cambios a la VM:

- **Iteración rápida**: editar en local → `make sync RESTART=1`. No pasa por git.
- **Definitiva**: `git commit && git push` → en la VM `cd /opt/zomboid-server && git pull` →
  `make restart`. Es la que deja la VM reproducible desde cero.

Entrar a la VM: `ssh pz@$(tofu -chdir=infra/terraform/envs/prod output -raw public_ip)`.

### RCON desde la PC del admin

El puerto 27015 del contenedor está bindeado a `127.0.0.1` dentro de la VM, así que no se llega
desde afuera aunque el NSG lo permita. Se usa `make remote-rcon` (que corre `rcon.sh` por SSH), o
un túnel si se quiere una sesión interactiva:

```bash
ssh -N -L 27015:127.0.0.1:27015 pz@<IP> &
./bin/mcrcon -H 127.0.0.1 -P 27015 -p '<rcon_password>' -t
```

---

## 5. Agregar o sacar mods

Flujo completo en `docs/mods.md`. Resumen:

1. Buscar el mod en el Workshop y anotar el **Workshop ID** (el `?id=NNNN` de la URL) y el
   **Mod ID** (el campo `id=` del `mod.info`, en B42 dentro de la carpeta `42/`).
2. Agregar la línea a `config/mods.txt`, respetando el orden (es el load order):
   ```
   3750253491  VB_CommonSense  # Common Sense [B42.20+]
   ```
3. `make sync RESTART=1` (o commit + `git pull` + `make remote-restart`).
4. Verificar en el log que baja y carga:
   ```bash
   make remote-logs
   # Workshop: download 352656/352656 ID=3750253491
   # LOG : Mod > loading VB_CommonSense
   ```
5. Los clientes bajan los mods solos al conectarse.

Sacar un mod: comentar o borrar la línea y `make remote-restart`. **Sacar un mod de una partida en
curso puede romper saves** (objetos y recetas que ya no existen): hacer `make remote-backup` antes.

---

## 6. Reinicio y actualización

### Reinicio

```bash
make remote-restart      # aviso a los jugadores, save, quit, up
```

Para cambios del `ini` que soportan recarga en caliente alcanza con:

```bash
make remote-rcon CMD=reloadoptions
```

(los mods y la mayoría de las sandbox vars **no** se recargan en caliente).

### Actualizar la imagen / el juego

La imagen está pinneada por digest en `docker-compose.yml`: nada se actualiza solo. Para tomar una
versión nueva:

```bash
# En cualquier máquina con docker:
docker pull danixu86/project-zomboid-dedicated-server:latest
docker image inspect danixu86/project-zomboid-dedicated-server:latest \
  --format '{{index .RepoDigests 0}}'
# -> danixu86/project-zomboid-dedicated-server@sha256:XXXX
```

Pegar ese `sha256:...` en el campo `image:` de `docker-compose.yml`, commitear, y en la VM:

```bash
ssh pz@<IP> 'cd /opt/zomboid-server && git pull && ./scripts/update.sh'
```

`scripts/update.sh` hace: backup etiquetado `pre-update` → apagado limpio → `docker compose pull` →
`make up`. Después verificar la versión:

```bash
make remote-logs | grep -i 'version='
```

### Actualizaciones del SO

`unattended-upgrades` está activo con **reboot automático desactivado**: reiniciar con jugadores
conectados pierde progreso. Para reiniciar la VM a mano:

```bash
make remote-down
ssh pz@<IP> 'sudo reboot'
```

El `zomboid.service` levanta el server solo en el próximo boot.

---

## 7. Backups y restore

### Cómo funciona

- **Nativos del server**: `BackupsCount=5`, `BackupsPeriod=60`, `BackupsOnStart=true`, en
  `data/zomboid/backups/`. Son la red de seguridad de corto plazo.
- **`scripts/backup.sh`**: `save` por RCON (si el server está arriba) → espera 5 s → `tar.zst` de
  `Saves/Multiplayer/servertest`, `Server/` y `db/` → `backups/zomboid-YYYYmmdd-HHMM[-etiqueta].tar.zst`
  → `rclone copy` al bucket → borra los locales de más de 3 días.
- **Cron diario** a las **06:00 hora de Buenos Aires** (`/etc/cron.d/zomboid`, log en
  `/var/log/zomboid/backup.log`).
- **Retención en el bucket**: 30 días, por lifecycle rule de Object Storage (`backup_retention_days`).
- **Autenticación**: `rclone` usa el backend `oracleobjectstorage` con
  `provider = instance_principal_auth`. **No hay ninguna credencial en la VM**: los permisos salen
  del dynamic group + policy que crea OpenTofu.

Backup manual:

```bash
make remote-backup
# o con etiqueta, dentro de la VM:
ssh pz@<IP> 'cd /opt/zomboid-server && ./scripts/backup.sh antes-de-probar-mods'
```

Listar lo que hay en el bucket:

```bash
ssh pz@<IP> 'rclone lsl oci:zomboid-backups'
```

### Restore

```bash
ssh pz@<IP>
cd /opt/zomboid-server
rclone lsl oci:zomboid-backups
./scripts/restore.sh oci:zomboid-backups/zomboid-20260903-0600.tar.zst
```

`restore.sh` pide confirmación (escribir `restore`), apaga el server limpio, guarda un backup de
seguridad etiquetado `pre-restore`, borra el mundo actual, extrae y levanta el server.

Con `--yes` no pregunta. Desde un archivo local: `./scripts/restore.sh backups/zomboid-....tar.zst`.

### Reconstruir todo desde cero

```bash
make infra-destroy      # borra VM, boot volume, VCN, compartment. El BUCKET NO se borra si tiene objetos.
make infra-apply        # VM nueva, IP nueva (la reservada se recrea)
ssh pz@<IP> 'cd /opt/zomboid-server && ./scripts/restore.sh --yes oci:zomboid-backups/<ultimo>.tar.zst'
```

> La IP reservada se destruye y se recrea con `tofu destroy`/`apply`: los amigos van a tener que
> actualizar el favorito. Para conservar la IP entre reconstrucciones habría que sacar
> `oci_core_public_ip` del ciclo de vida del módulo (no está hecho: no vale la complejidad para un
> caso que pasa una vez).

---

## 8. Wipe y arranque de la partida definitiva

El plan es: partida de prueba sin mods → validación con un amigo → **wipe** → partida definitiva.

```bash
ssh pz@<IP>
cd /opt/zomboid-server
./scripts/wipe.sh          # pide escribir 'wipe'
```

`wipe.sh` hace: apagado limpio → backup etiquetado `pre-wipe` (queda en el bucket) → borra
`Saves/Multiplayer/servertest`, `db/` y los backups nativos. **No levanta el server**: es a
propósito, porque antes hay que definir la partida.

Después del wipe, en la PC del admin:

1. Editar `config/servertest_SandboxVars.lua`. **Varias opciones quedan fijadas al crear el mundo**
   (tamaño del mapa de loot, población inicial de zombies, velocidad de erosión): cambiarlas
   después no aplica del todo.
2. Descomentar los mods definitivos en `config/mods.txt`.
3. Revisar `config/servertest.ini.tpl`: `PVP`, `MaxPlayers`, `SafetySystem`.
4. `git commit` + `git push`.
5. En la VM: `git pull && make up`.

**No cambiar `ServerPlayerID` ni `ResetID`** en el `.tpl`: si cambian, los clientes son forzados a
crear personaje nuevo. Están versionados justamente para poder reconstruir la VM sin que eso pase.

---

## 8.1 Borrar todo (`make destroy-all`)

```bash
make destroy-all              # pide escribir el public_name para confirmar
make destroy-all DRY_RUN=1    # muestra los pasos sin tocar nada
```

`scripts/destroy-all.sh` hace, en orden: leer `public_ip` del state; si la VM responde por SSH,
`./scripts/backup.sh final` (si falla, pregunta si borrar igual); `tofu destroy -auto-approve`; y
al final imprime qué quedó vivo y cómo borrarlo.

**Qué NO borra `tofu destroy`**: el bucket de Object Storage si todavía tiene objetos (OCI se
niega a borrar un bucket no vacío), y por lo tanto tampoco el compartment. Para dejar la cuenta
completamente limpia:

```bash
oci os object bulk-delete --bucket-name zomboid-backups --namespace <namespace>
oci os bucket delete --bucket-name zomboid-backups --namespace <namespace>
```

y después borrar el compartment `zomboid` desde la consola (*Identity → Compartments*).

Si no hay state local (la infra se creó desde otra máquina), el script lo dice y no hace nada:
hay que borrar desde esa máquina o a mano en la consola.

---

## 9. Fase 3: on-demand (código listo, sin cron todavía)

Encender y apagar la VM a mano desde la PC del admin (requiere el CLI `oci` de §1.4):

```bash
./scripts/cloud-stop.sh     # stop.sh + backup por SSH, después SOFTSTOP de la instancia
./scripts/cloud-start.sh    # START + espera a RUNNING
```

Con la instancia en `STOPPED`, OCI **no cobra cómputo**: queda el boot volume (~2-3 USD/mes) y la IP
reservada (gratis).

`scripts/idle-shutdown.sh` (0 jugadores durante `IDLE_MINUTES` → stop + backup + `shutdown -h now`)
**está escrito pero no está en el cron**: la línea está comentada en `/etc/cron.d/zomboid`. Se
activa recién cuando exista el bot de Discord que pueda prender la VM; si no, apagarla dejaría a los
amigos sin forma de volver a entrar.

Probarlo sin riesgo: `DRY_RUN=1 ./scripts/idle-shutdown.sh`.

---

## 10. Costos y presupuesto

OpenTofu crea un `oci_budget_budget` mensual de `budget_usd` (default 25 USD) sobre el tenancy, con
dos alertas al mail de `alert_email`:

- **FORECAST 80%**: la proyección de fin de mes supera el 80% del presupuesto (avisa temprano).
- **ACTUAL 100%**: el gasto real llegó al presupuesto (avisa tarde pero seguro).

Las alertas de budget **no apagan nada**: son solo mail. Verlas en consola: *Billing & Cost
Management → Budgets*.

Si la cuenta todavía no tiene permisos sobre el compartment raíz, poner `enable_budget = false` en
`terraform.tfvars` y crear el budget a mano desde la consola.

Costo esperado (PLAN.md §4): ~92 USD/mes always-on, ~11-15 USD/mes con el patrón on-demand de la
Fase 3.

---

## 11. Troubleshooting

### "Server has different version than client" / mismatch de versión

El cliente y el server están en builds distintos de B42.

1. Ver la versión del server: `make remote-logs | grep -i 'version='` (ej. `version=42.20.4`).
2. En el cliente, Steam → Project Zomboid → Propiedades → Betas: tiene que estar en **None /
   default** (B42 es la rama estable desde el 29-jul-2026). Si dice `legacy41`, eso es B41.
3. Forzar la actualización del cliente (Steam → Descargas) y verificar integridad de los archivos.
4. Si el server quedó adelantado porque se actualizó la imagen, se puede volver al digest anterior
   en `docker-compose.yml` y correr `./scripts/update.sh`.

### Mismatch de mods / "You have different mods"

El cliente tiene una versión distinta de un mod, o le falta.

1. El cliente tiene que estar suscrito al mod en el Workshop y con el Workshop habilitado. Los mods
   del server se bajan solos al conectarse; a veces hace falta reiniciar el cliente.
2. Si un mod se actualizó en el Workshop, el server toma la versión nueva **solo al reiniciar**:
   `make remote-restart`.
3. Si un mod se actualizó y rompe la partida: sacarlo de `config/mods.txt`, `make remote-restart`, y
   si el mundo quedó dañado, `restore.sh` sobre el último backup bueno.
4. Cache de Workshop corrupta en el server:
   ```bash
   make remote-down
   ssh pz@<IP> 'rm -rf /opt/zomboid-server/data/workshop/content'
   make remote-up      # los vuelve a bajar
   ```

### "Checksum mismatch" al conectarse

El cliente tiene archivos del juego o de un mod distintos a los del server.

1. Cliente: Steam → Propiedades → Archivos instalados → **Verificar integridad**.
2. Cliente: desuscribirse y volver a suscribirse al mod que aparece en el mensaje, y borrar
   `~/Zomboid/Workshop` (Linux) o `%USERPROFILE%\Zomboid\Workshop` (Windows).
3. Server: borrar `data/workshop/content` como arriba y reiniciar.

### El server no arranca después de un `tofu apply`

```bash
ssh pz@<IP>
sudo cloud-init status --long        # 'status: error' = falló alguna etapa
sudo tail -100 /var/log/cloud-init-output.log
```

Causas frecuentes:

- **`Permission denied (publickey)` al clonar el repo**: solo pasa con `repo_url` SSH. La deploy
  key no está cargada en GitHub, o se cargó otra. Cargar el output `deploy_public_key` y después,
  en la VM:
  ```bash
  sudo cloud-init clean --logs && sudo reboot
  ```
- **`could not read Username for 'https://github.com'`**: `repo_url` es HTTPS pero el repo es
  privado. Hacerlo público, o volver a correr `./setup.sh` para pasar a SSH + deploy key.
- **`make mcrcon` falla**: faltó `build-essential`; reintentar a mano en la VM.
- **El pull de la imagen tarda**: son 10.4 GB. `docker compose logs` no muestra nada hasta que
  termina. Paciencia (`TimeoutStartSec=1800`).

### No entra por SSH

Casi siempre es `admin_cidr`: cambió la IP pública del admin.

```bash
./setup.sh        # detecta la IP nueva y reescribe admin_cidr (Enter a todo lo demás)
make deploy       # solo cambia la regla del NSG, no toca la VM ni la partida
```

A mano:

```bash
curl -s https://ifconfig.me
$EDITOR infra/terraform/envs/prod/terraform.tfvars   # actualizar admin_cidr
make infra-apply                                     # solo cambia la regla del NSG
```

Si sigue sin andar, revisar en consola que la instancia esté **RUNNING** (puede haberse apagado).

### Los amigos no pueden entrar pero el server está arriba

1. `make remote-status` → ¿dice `*** SERVER STARTED ****` en el log?
2. ¿Están usando el puerto **16261** y no 27015?
3. Verificar el NSG en consola: tiene que haber una regla ingress UDP 16261-16262 desde `0.0.0.0/0`.
4. Desde la VM: `sudo ufw status` (16261:16262/udp allow) y `docker compose ps` (los puertos
   publicados).

- Si lo anterior está bien, abrir también **UDP 8766-8767**: guías viejas y el compose de referencia de la imagen los listan como puertos de Steam; pzwiki para B42 solo lista 16261-16262 (incertidumbre documentada en `docs/research/01-b42-server-install.md`). Para abrirlos: agregar la regla al NSG en `infra/terraform/modules/oci/main.tf` (rango 8766-8767/udp), publicar `8766-8767/udp` en `docker-compose.yml`, `make infra-apply` y `make sync RESTART=1`.

### El backup no sube al bucket

```bash
ssh pz@<IP>
rclone lsd oci:                    # ¿lista los buckets?
cat /var/log/zomboid/backup.log
```

Si da `NotAuthorizedOrNotFound`, la policy o el dynamic group todavía no propagaron (tarda hasta
unos minutos después del `apply`) o el matching rule no matchea la instancia:
consola → *Identity & Security → Domains → Default → Dynamic groups → zomboid-vm-dg*, comparar el
OCID de la regla con `tofu output -raw instance_ocid`.

### El mundo se corrompió

`restore.sh` sobre el último backup bueno (§7). Los backups nativos del server también sirven:
están en `data/zomboid/backups/` como zips con fecha.

---

## 12. Validar cambios de infraestructura sin aplicar

```bash
tofu -chdir=infra/terraform/envs/prod validate
tofu fmt -check -recursive infra/terraform
```

Validar `infra/cloud-init.yaml` (es un template de OpenTofu, hay que renderizarlo primero). Eso lo
hace `scripts/render-cloud-init.sh`, que arma una config descartable con un solo `output` que
llama a `templatefile(...)` con valores de ejemplo. **Hay que probar los dos modos de clonado**,
porque el template tiene condicionales `%{ if use_deploy_key ~}`:

```bash
scripts/render-cloud-init.sh https /tmp/ci-https.yaml
scripts/render-cloud-init.sh ssh   /tmp/ci-ssh.yaml

docker run --rm -v /tmp:/mnt ubuntu:24.04 bash -c \
  'apt-get update -qq && apt-get install -y -qq cloud-init >/dev/null &&
   cloud-init schema --config-file /mnt/ci-https.yaml &&
   cloud-init schema --config-file /mnt/ci-ssh.yaml'
# -> Valid schema /mnt/ci-https.yaml
# -> Valid schema /mnt/ci-ssh.yaml
```

Es lo mismo que corre el job `cloud-init` del CI (`.github/workflows/ci.yml`).

Los scripts:

```bash
docker run --rm -v "$PWD:/mnt" -w /mnt koalaman/shellcheck:stable -x setup.sh scripts/*.sh scripts/lib/*.sh
```

Y los secretos, sobre todo el historial completo:

```bash
docker run --rm -v "$PWD:/repo" zricethezav/gitleaks:latest detect --source /repo --no-banner
```
