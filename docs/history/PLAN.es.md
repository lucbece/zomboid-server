# Plan: servidor dedicado de Project Zomboid Build 42 en la nube

> **Historical document.** This is the original planning document for the project, written in
> Spanish while the server was being built. It is kept for the record and is not maintained.
> The decisions that are actually in force live in [`README.md`](../../README.md),
> [`docs/architecture.md`](../architecture.md) and [`docs/runbook.md`](../runbook.md).

Fecha del plan: 2026-09-03. Investigación completa en `docs/research/` (leer antes de implementar cada fase).

## 0. Resumen ejecutivo

- **Objetivo**: servidor privado de PZ **Build 42** para 8 a 16 amigos, con mods de Workshop, corriendo en una VM en la nube, con toda la configuración (ini, sandbox, mods) versionada en este repo y deploy reproducible.
- **Estado de B42 (verificado 2026-09-03)**: **B42 es la rama estable por defecto de Steam desde el 29-jul-2026 (42.20)**. No hace falta `-beta`. El multiplayer B42 existe desde 42.13 (dic-2025). Versión actual: 42.20.x. Para B41 habría que usar `-beta legacy41`.
- **Arquitectura elegida**: Docker Compose + imagen `danixu86/project-zomboid-dedicated-server` (la única mantenida activamente con soporte explícito para B42 y opción de no pisar el ini) + directorio `config/` bind-mounteado desde git + scripts de RCON/backup + cloud-init + Terraform/OpenTofu para la VM.
- **Hosting (decidido)**: **Oracle Cloud São Paulo (`sa-saopaulo-1`)**, ~30 ms desde Buenos Aires, x86 Flex 4 OCPU / 16 GB, pago por uso. **On-demand**: la VM se apaga sola sin jugadores y se prende con un bot de Discord; sin dominio (IP reservada gratis). Ver §4 y §4.1.
- **Tamaño**: apuntar a **4 vCPU / 16 GB RAM / 60-80 GB SSD** para las dos variantes (8 y 16 jugadores); el heap de la JVM se ajusta con `MAX_MEMORY` (8 GB para 8 jugadores, 12 GB para 16). Con 8 GB de host solo alcanza para 8 jugadores y ajustado (B42 es más pesado que B41).

## 1. Decisiones ya tomadas (no re-litigar al implementar)

| Tema | Decisión | Por qué |
|---|---|---|
| Runtime | Docker Compose sobre Ubuntu 24.04 LTS | Reproducible entre proveedores; la imagen encapsula steamcmd + JRE. Bare metal y LinuxGSM descartados (menos reproducible, sin pin de versión). |
| Imagen | `danixu86/project-zomboid-dedicated-server`, pinneada por digest | Última push 2026-09-01; issue #39 cerrado hace que `STEAMAPPBRANCH` vacío siga la rama pública (= B42). `SELF_MANAGED_MODS=1` evita que el entrypoint reescriba `Mods=`/`WorkshopItems=`. |
| Fallback de imagen | Dockerfile propio (`steamcmd/steamcmd:ubuntu-24` + `app_update 380870` + `start-server.sh`) | Solo si en la Fase 1 se comprueba que el entrypoint de Danixu pisa otras claves del ini además de mods. |
| Fuente de verdad de config | `config/servertest.ini.tpl` + `config/servertest_SandboxVars.lua` + `config/servertest_spawnregions.lua` en git | El usuario edita estos archivos para mods y ajustes de partida. Los secretos (`Password`, `RCONPassword`, `DiscordToken`) se inyectan desde `.env` (gitignored) con `envsubst` en `scripts/render-config.sh`. |
| Apagado | Siempre `save` + `quit` vía RCON, nunca `docker stop` a secas | El server no maneja SIGTERM limpiamente (confirmado por The Indie Stone). `stop_grace_period` alto como red de seguridad. |
| Backups | Nativos del server (`BackupsCount`, `BackupsPeriod`) + tar de `Saves/Multiplayer/<nombre>` y `Server/` tras `save`, subidos con `rclone` a object storage | Los saves son archivos + SQLite; copiar en caliente sin `save` previo puede dar archivos rotos. |
| Nombre del server | `servertest` | Es el default y todos los archivos (`servertest.ini`, `servertest_SandboxVars.lua`) se nombran a partir de él. Cambiarlo obliga a renombrar todo. |
| IaC | OpenTofu (compatible con Terraform) con un módulo por proveedor + cloud-init común | La VM es intercambiable; lo que persiste es el repo + el backup. |

## 2. Estructura objetivo del repo

```
zomboid-server/
├── PLAN.md                     # este documento
├── CLAUDE.md                   # contexto para agentes que implementen fases
├── README.md                   # cómo usar (se completa en Fase 1)
├── docker-compose.yml          # imagen pinneada, volúmenes, puertos, env
├── .env.example                # variables + secretos (copiar a .env)
├── Makefile                    # atajos: render, up, down, rcon, backup, restore, restart
├── config/
│   ├── servertest.ini.tpl      # ini con ${PLACEHOLDERS} para secretos
│   ├── servertest_SandboxVars.lua
│   ├── servertest_spawnregions.lua
│   └── mods.txt                # (opcional) lista "workshop_id  mod_id  # nombre" → genera Mods/WorkshopItems
├── bot/                        # bot de Discord (Fase 3): discord.py + SDK oci
├── scripts/
│   ├── render-config.sh        # .tpl + .env (+ mods.txt) → config/servertest.ini
│   ├── rcon.sh                 # wrapper de mcrcon (players, save, servermsg, quit)
│   ├── restart.sh              # aviso a jugadores, save, quit, compose up
│   ├── backup.sh               # save → tar → rclone
│   ├── restore.sh              # bajar server, restaurar tar, subir
│   ├── update.sh               # actualiza imagen/juego respetando shutdown limpio
│   ├── idle-shutdown.sh        # cron: 0 jugadores por N min → stop.sh + shutdown
│   └── cloud-start.sh / cloud-stop.sh  # oci cli desde la PC del admin
├── infra/
│   ├── cloud-init.yaml         # docker + git clone del repo + systemd unit que hace compose up
│   ├── systemd/zomboid.service # compose up en boot, ExecStop = scripts/stop.sh (save+quit)
│   └── terraform/
│       ├── modules/oci/        # VCN, security list, IP reservada, instancia, bucket
│       └── envs/prod/
├── docs/
│   ├── research/               # 4 documentos de investigación con fuentes
│   ├── runbook.md              # operación diaria (Fase 2)
│   └── mods.md                 # cómo agregar/quitar mods (Fase 2)
└── data/                       # gitignored; bind mounts locales para pruebas
```

## 3. Datos técnicos clave (para no volver a buscarlos)

Fuente detallada: `docs/research/01-b42-server-install.md` y `04-server-config-and-mods.md`.

- **Steam App ID** del server dedicado: `380870` (cliente: `108600`). Rama: pública/estable = B42. Sin password de beta.
- **Puertos**: `16261/udp` y `16262/udp` (juego, confirmados en pzwiki para B42). `27015/tcp` RCON, **solo abrir a la IP del admin**. `8766-8767/udp` (Steam) aparecen en guías viejas y en el compose de Danixu; no confirmados como necesarios en B42, abrirlos no hace daño.
- **Rutas dentro del contenedor** (Danixu): datos del server en `/home/steam/Zomboid` (`Server/servertest.ini`, `Server/servertest_SandboxVars.lua`, `Saves/Multiplayer/servertest/`, `Logs/`, `db/`), Workshop en `/home/steam/pz-dedicated/steamapps/workshop`. Ambos deben ser volúmenes persistentes.
- **Env vars Danixu**: `ADMINUSERNAME`, `ADMINPASSWORD` (obligatoria en el primer arranque; evita el prompt interactivo), `MIN_MEMORY`/`MAX_MEMORY` (heap JVM; setear solo `MAX_MEMORY`), `RCONPASSWORD`, `SELF_MANAGED_MODS=1`, `CACHEDIR`, `SERVERNAME`. Build-arg `STEAMAPPBRANCH` dejar **vacío**.
- **Heap**: JRE incluida (Java 25, GraalVM). 8 jugadores → `-Xmx8g`; 16 → `-Xmx12g` a `16g`. El proceso no usa más RAM que `-Xmx`; un `-Xmx` chico tira el server aunque sobre RAM.
- **Mods**: `WorkshopItems=` IDs numéricos separados por `;` (los baja el server con su steamcmd al arrancar). `Mods=` IDs de `mod.info` separados por `;`. En B42 los mods traen carpetas `common/` y `42/` (ahí está `mod.info`). **Incertidumbre a resolver empíricamente en Fase 1**: B42 temprano exigía prefijo `\` por ID (`Mods=\ModA;\ModB`); en 42.20.x parece no hacer falta. Probar sin prefijo primero; si un mod no carga, probar con prefijo. Los clientes descargan los mods solos al conectarse (necesitan tener el Workshop habilitado).
- **Cambios de config**: `servertest.ini` se relee con el comando admin `reloadoptions`, pero mods y la mayoría de sandbox vars requieren reinicio. Cambiar sandbox vars después de crear el mundo no aplica todo: algunas quedan fijadas al crear la partida (por eso definir el sandbox **antes** del primer arranque real).
- **RCON**: cliente `mcrcon` (`mcrcon -H <ip> -P 27015 -p <pass> "save"`). Comandos útiles: `players`, `save`, `quit`, `servermsg "texto"`, `adduser`, `setaccesslevel <user> admin`, `reloadoptions`, `kickuser`, `banuser`.
- **Whitelist**: server privado ⇒ `Open=false` + `Password=` o whitelist con `/adduser`. Para amigos, lo más simple: `Open=true` + `Password=` fuerte + `Public=false`.
- **Ejemplos de mods B42 verificados (re-chequear al instalar, el ecosistema está en flujo tras 42.20)**: Common Sense `3750253491`/`VB_CommonSense`; Inventory Tetris B42 MP patch `3688186430`/`INVENTORY_TETRIS`; True Music B42 `3397198968`/`truemusic`; Brita's B42 Armor Pack `3777418909`/`BritasArmorPackB42`.
- **pzwiki bloquea fetch desde sandboxes** (Cloudflare 403). Si un agente necesita releer, usar `https://r.jina.ai/https://pzwiki.net/wiki/<Pagina>`. Páginas: `Dedicated_server`, `Startup_parameters`, `Server_settings`, `Sandbox_options`, `Admin_commands`.

## 4. Hosting: opciones y recomendación

**Restricción confirmada por el usuario (2026-09-03): todos los jugadores están en Argentina y quieren el menor ping razonable.** Eso ordena las opciones por latencia primero y precio después.

Latencia aproximada desde Buenos Aires (fuentes en `docs/research/03-cloud-hosting.md`, números de WonderNetwork + estimaciones):

| Destino | Ping aprox. | Comentario |
|---|---|---|
| Buenos Aires (AWS Local Zone `us-east-1-bue-1`, Latitude.sh, Gcore) | 5-15 ms | Lo mejor posible. Oferta acotada y cara. |
| São Paulo (OCI Vinhedo, AWS sa-east-1, GCP, Azure, Linode, Vultr) | ~30 ms | Excelente para PZ; diferencia con BA imperceptible en juego. |
| Santiago (OCI `sa-santiago-1`, GCP `southamerica-west1`) | ~25-35 ms | Equivalente a São Paulo, menos oferta. |
| US East (Ashburn) | ~140 ms | Jugable pero se nota en combate/vehículos. |
| Alemania (Hetzner) | ~230 ms | Descartado. |

Detalle y fuentes con fecha: `docs/research/03-cloud-hosting.md`. Precios USD/mes al 2026-09-03; **recheckear antes de contratar**. Supuestos: ~20 h/semana de juego (~87 h/mes) para la variante on-demand.

| Opción | Región | 16 GB always-on | 16 GB on-demand | Notas |
|---|---|---|---|---|
| **Oracle Cloud x86 Flex (E4/E5)** | Vinhedo (SP) | ~$92 | **~$11-15** | Mismo precio en todas las regiones. Instancia detenida no cobra cómputo. IP pública reservada gratis. **Recomendada.** |
| **AWS Local Zone Buenos Aires** | Buenos Aires | $226 (t3.xlarge 4 vCPU/16 GB) + $20 EBS gp2 80 GB | ~$27 + $20 EBS | El menor ping posible (~5-15 ms). Sin spot ni reservadas. Solo 16 tipos de instancia; t3.xlarge es la única de 16 GB razonable. Vale la pena solo si 30 ms vs 10 ms importa al grupo. |
| AWS sa-east-1 | São Paulo | ~$223 (m5.xlarge) | ~$27 | Stop = sin cobro de cómputo (sí disco e IPv4 ~$3.6/mes). Región cara. |
| Linode/Akamai | São Paulo | $134 (Linode 16 GB) | no aplica* | Precio confirmado y simple. *Cobra la instancia apagada; on-demand requiere destruir/recrear desde snapshot. |
| Latitude.sh / Gcore | Buenos Aires | a verificar | a verificar | Bare metal (Latitude) y cloud (Gcore) con datacenter en BA. No investigados en detalle; chequear si ofrecen VM x86 de 16 GB y a qué precio antes de descartarlos. |
| Hetzner | Ashburn / Alemania | CPX41 ~$100+ / CCX23 ~€86 | no aplica* | Subió precios 2-3x en jun-2026; sin región SA; ~140-230 ms. Descartado. |
| Oracle Always Free ARM | cualquiera | $0 | $0 | Recortado a 2 OCPU/12 GB (jun-2026) y PZ es x86 (requiere emulación box64/FEX, inestable). Descartado. |
| Hosting administrado (BisectHosting, G-Portal, etc.) | algunos con Brasil | $24 (8 GB) / $48 (16 GB) | no aplica | Baseline honesto: más barato que always-on self-hosted. Sin root ni IaC. Verificar que el plan elegido sea en São Paulo. |

**Recomendación**: Oracle Cloud en Brasil (São Paulo `sa-saopaulo-1`; el análisis de precio se hizo sobre Vinhedo, que cuesta lo mismo), shape `VM.Standard.E5.Flex` (o E4) con 4 OCPU / 16 GB, boot volume 80 GB, con el patrón on-demand de la Fase 3. Da ~30 ms, que para PZ es indistinguible de jugar en LAN, a una fracción del costo de la Local Zone de Buenos Aires. Si el grupo quiere sí o sí el mínimo ping y el presupuesto lo permite, la alternativa es AWS Local Zone BA con t3.xlarge on-demand (~$47/mes con disco). Si nadie quiere operar nada y el server va a estar siempre prendido, considerar hosting administrado en São Paulo y usar este repo solo para la config.

**Decisiones tomadas por el usuario (2026-09-03)**:
1. **Proveedor: Oracle Cloud, región Brazil East (São Paulo, `sa-saopaulo-1`)**. Cuenta creada 2026-09-03 con esa home region porque Vinhedo no permitió el registro; misma latencia y mismo precio, shape `VM.Standard.E5.Flex` 4 OCPU / 16 GB, boot volume 80 GB. AWS descartado por precio.
2. **Modelo de encendido: on-demand obligatorio.** El mundo se pausa con `PauseEmpty=true` (ajuste nativo de PZ: el tiempo de juego no avanza sin jugadores), pero eso no baja el costo: la VM prendida cobra igual (~$90/mes). Por eso la VM **se apaga sola cuando no hay jugadores** y **se prende desde Discord**. En OCI una instancia Standard detenida no cobra cómputo (verificado en docs.oracle.com, "Resource Billing for Stopped Instances"); queda solo el boot volume (~$2-3/mes) y la IP reservada (gratis). Costo esperado: $10-20/mes según horas jugadas. La Fase 3 deja de ser opcional.
3. **Sin dominio.** No es necesario: OCI da una **IP pública reservada gratis** que no cambia entre stop/start; los amigos se conectan por `IP:16261` y la guardan como favorito en el cliente. OCI no provee un hostname público para VMs. Si algún día se quiere un nombre, un dominio barato + Cloudflare DNS (gratis) es un cambio de 10 minutos.
4. **Discord: hay grupo.** Se usan las dos integraciones de §4.1.

### 4.1 Integración con Discord

Hay dos piezas independientes:

**a) Puente nativo de PZ (config del ini, sin código)**. El server trae un cliente de Discord incorporado; hace falta crear una app/bot en el Developer Portal de Discord, invitarlo al servidor con permisos de leer/escribir mensajes y poner su token en `.env`.
- `DiscordEnable=true`, `DiscordToken=${DISCORD_TOKEN}`.
- `DiscordChatChannel=<nombre-canal>`: puente **bidireccional** entre el chat global del juego y ese canal. Lo que se escribe en Discord aparece en el juego y viceversa.
- `DiscordLogChannel=<nombre-canal>`: logs del server (conexiones, desconexiones, eventos).
- `DiscordCommandChannel=<nombre-canal>`: ejecutar comandos de admin desde Discord (restringir el canal a admins con permisos de Discord).
- Limitación: solo funciona mientras el server está prendido. No puede prender la VM.

**b) Bot propio para operar la VM (Fase 3, código nuestro)**. Corre **fuera** de la VM del juego, porque tiene que poder prenderla. Opción recomendada: instancia **Always Free ARM de OCI** (2 OCPU / 12 GB, gratis, en la misma tenancy; los recursos Always Free viven en la home region, así que la home region es São Paulo) con un bot Python (`discord.py` + SDK `oci`). Alternativas: Cloudflare Worker con Discord Interactions (gratis, más complejo de firmar requests a OCI) o una Raspberry/PC local siempre prendida.
Funciones, en orden de valor:
1. `/pz start`: prende la VM, espera a que el server responda por RCON y anuncia "Server listo en IP:16261" en el canal. Cualquier miembro con el rol `zomboid` puede usarlo.
2. `/pz status`: estado de la VM (running/stopped), jugadores conectados (RCON `players`), tiempo desde el último backup, versión del juego.
3. `/pz stop` (solo admins): aviso de 60 s en el juego, `save`, `quit`, backup, apagar VM.
4. **Auto-apagado**: cron en la VM cada 5 min consulta `players`; tras 30 min con 0 jugadores ejecuta el stop limpio y `shutdown -h now` (OCI deja la instancia en STOPPED). El bot detecta el apagado y avisa en Discord.
5. Avisos automáticos: entradas y salidas de jugadores (si no se usa el `DiscordLogChannel` nativo), muertes de personajes (parseo de logs del server), inicio y fin de backups, reinicio programado para tomar updates de mods.
6. `/pz restart` (admins): reinicio limpio para aplicar cambios de mods/config después de un `git pull` en la VM.
7. `/pz mods`: lista de mods activos leyendo el ini.
8. `/pz backup` (admins) y `/pz backups`: forzar backup y listar los disponibles en object storage.
9. Opcional: `/pz whitelist add <usuario>` vía RCON `adduser` si se pasa a whitelist en lugar de password compartido.

## 5. Fases de implementación

Cada fase tiene tareas concretas y criterios de aceptación. Están pensadas para ejecutarse con modelos más baratos; el contexto necesario está en `CLAUDE.md` y `docs/research/`.

### Fase 1: servidor reproducible en local (Docker Compose) — **HECHA 2026-09-03**

Objetivo: `make up` levanta un server B42 en la PC local (la `lucpc` tiene Docker), con config desde git, mods de prueba y apagado limpio. Sin nube todavía.

Tareas (todas hechas el 2026-09-03; ver el bloque "Resultado de la Fase 1" al final de la fase):
1. [x] **Verificar el entrypoint de Danixu**: leer `entrypoint.sh` en https://github.com/Danixu/project-zomboid-server-docker y documentar en `docs/research/02-docker-and-tooling.md` (sección "Verificación") exactamente qué claves del ini reescribe con `SELF_MANAGED_MODS=1`. Si reescribe algo fuera de `Mods`/`WorkshopItems` que necesitemos controlar desde git, activar el fallback de Dockerfile propio (§1).
2. [x] **`docker-compose.yml`**: imagen pinneada por digest (`docker pull` y anotar el digest), `SELF_MANAGED_MODS=1`, `MAX_MEMORY` desde `.env`, puertos `16261-16262/udp`, `27015/tcp` bindeado a `127.0.0.1` (en la nube se abre por firewall solo al admin), volúmenes `./data/zomboid:/home/steam/Zomboid` y `./data/workshop:/home/steam/pz-dedicated/steamapps/workshop`, `stop_grace_period: 120s`, `restart: unless-stopped`. Resolver UID/GID del usuario `steam` de la imagen para que los bind mounts sean escribibles.
3. [x] **`.env.example`**: `ADMINUSERNAME`, `ADMINPASSWORD`, `RCONPASSWORD`, `SERVER_PASSWORD`, `MAX_MEMORY=8g`, `PUBLIC_NAME`, `MAX_PLAYERS=16`, `DISCORD_*` vacíos.
4. [x] **`config/servertest.ini.tpl`**: arrancar el server una vez sin config para que genere `servertest.ini` por defecto en `data/zomboid/Server/`, copiarlo al repo como `.tpl` y reemplazar secretos por `${VAR}`. Ajustar para server privado: `Public=false`, `Open=true`, `Password=${SERVER_PASSWORD}`, `MaxPlayers=${MAX_PLAYERS}`, `PVP=false` (a decidir), `PauseEmpty=true`, `SaveWorldEveryMinutes=10`, `BackupsCount=5`, `BackupsPeriod=60`, `RCONPort=27015`, `RCONPassword=${RCONPASSWORD}`, `UPnP=false`, `Mods=`, `WorkshopItems=`. Lo mismo con `servertest_SandboxVars.lua` y `servertest_spawnregions.lua` (copiar los generados al repo).
5. [x] **`scripts/render-config.sh`**: `set -a; source .env; envsubst < config/servertest.ini.tpl > data/zomboid/Server/servertest.ini` y copiar los `.lua`. Debe fallar si falta una variable (usar `envsubst` con lista explícita o chequear `${VAR:?}`). Si se implementa `mods.txt`, generar aquí las líneas `Mods=`/`WorkshopItems=` preservando el orden del archivo (el orden de `Mods=` es el load order).
6. [x] **`scripts/rcon.sh`**: instalar `mcrcon` (apt en Debian/Ubuntu 24.04 o compilar desde https://github.com/Tiiffi/mcrcon) y envolverlo leyendo `.env`.
7. [x] **`scripts/stop.sh` y `scripts/restart.sh`**: `servermsg "Reinicio en 60s"`, sleep, `save`, `quit`, esperar a que el contenedor termine, (restart:) `render-config` + `compose up -d`.
8. [x] **`Makefile`** con `render`, `up`, `down` (= stop.sh), `restart`, `logs`, `rcon CMD=...`, `backup`, `restore FILE=...`.
9. [x] **Prueba de mods**: agregar 2 mods de la lista de §3 al ini, reiniciar, confirmar en logs que se descargan y cargan. Documentar si hizo falta el prefijo `\` en `docs/mods.md`.
10. [~] **Prueba end-to-end**: conectarse desde el cliente de Steam (B42) por IP local, jugar, `make down`, `make up`, confirmar que el mundo y el personaje persisten. — la parte automatizable está hecha y verificada (`up` → `rcon players` → `down` con `save`+`quit` → `up` reusando el mundo); **falta que el usuario entre con el cliente de Steam** y confirme que el personaje persiste (instrucciones en el README).

Aceptación: `make up` desde clon limpio + `.env` levanta el server en menos de 10 minutos; un cliente entra; `make down` deja el log con `save` y `quit` y sin errores; los mods de prueba cargan.

#### Resultado de la Fase 1 (2026-09-03, en `lucpc`)

**Aceptación: cumplida**, salvo la parte que solo puede hacer el usuario (conectarse con el cliente
de Steam, tarea 10).

- **Imagen**: se sigue con Danixu, **no** se activó el fallback de Dockerfile propio. Pinneada por
  digest en `docker-compose.yml`:
  `danixu86/project-zomboid-dedicated-server@sha256:a98b0f219f63ad9f08b0658cf77c2c165705ab8d74775fd3db6e50fd6f4961e1`
  (10.4 GB, trae el juego instalado, buildid `24909836`). Razón completa en
  `docs/research/02-docker-and-tooling.md` §7.6: con `SELF_MANAGED_MODS=1` y dejando sin definir
  `PASSWORD`/`PUBLIC`/`DISPLAYNAME`, el entrypoint solo escribe `RCONPassword` y `UDPPort`, y con los
  mismos valores que ya renderizamos.
- **Versión del juego que reportó el server**: `version=42.20.4 b0bbce05d5 demo=false`.
- **UID/GID del usuario `steam` de la imagen**: `1000:1000` (coincide con `luc` en `lucpc`). Además
  el entrypoint corre como root y hace `chown -R steam:steam` sobre los dos bind mounts, así que el
  problema de permisos documentado no se dio.
- **Arranque**: 26 s desde `docker compose up` hasta `*** SERVER STARTED ****` con el mundo ya
  generado; 2-4 min el primer arranque (worldgen + descarga del mod). Muy por debajo de los 10 min.
- **Mods**: `WorkshopItems=3750253491` / `Mods=VB_CommonSense` baja y carga
  (`Workshop: download 352656/352656 ID=3750253491`, `LOG : Mod > loading VB_CommonSense`).
  **Resultado empírico del prefijo `\`: es indiferente en 42.20.4** — `Mods=VB_CommonSense` y
  `Mods=\VB_CommonSense` producen exactamente el mismo `loading VB_CommonSense`. El repo usa la
  forma sin prefijo. Documentado en `docs/mods.md`.
- **Apagado limpio**: `make down` deja `World saved` + `Quit` y el contenedor sale en ~10 s.
- **Persistencia**: tras `make down` + `make up` el server reusa el mundo
  (`checking server WorldVersion in map_t.bin`, `Loading world...`) sin recrear
  `Saves/Multiplayer/servertest`.
- **RAM observada** con `MAX_MEMORY=8g` y 0 jugadores: 8.6 GiB de RSS del contenedor.

#### Desvíos respecto de lo planeado

1. **`stop.sh` tiene que desactivar el auto-restart antes del `quit`.** Con
   `restart: unless-stopped` (que el plan pide explícitamente), Docker vuelve a levantar el server
   apenas la JVM sale por el `quit` de RCON, así que el contenedor nunca termina y `stop.sh` caía
   siempre al timeout de 120 s. La solución es `docker update --restart=no <container>` antes de
   mandar el `quit`; el siguiente `docker compose up` restaura la política desde el yaml.
2. **Quirk del RCON de PZ 42.20.4**: el server contesta un paquete "tarde", así que `mcrcon` en modo
   no interactivo con un solo comando no imprime nada. `scripts/rcon.sh` agrega un `players` de
   descarte al final para vaciar la cola. Sin eso, `stop.sh` creía que el RCON estaba caído.
3. **`-modfolders` ya no existe en 42.20.4** (`unknown option "-modfolders"` en el log). Se sacó
   `MODFOLDERS` del compose; el default del engine (`workshop,steam,mods`) es el que queremos.
4. **`.env` lo leen dos parsers distintos** (el `source` de bash de los scripts y el parser de
   `docker compose`), y no coinciden en el escapado. Los valores con espacios van entre comillas
   (`PUBLIC_NAME="..."`), y un backslash literal solo funciona en los dos como `MOD_ID_PREFIX="\\"`.
5. **Se implementó `config/mods.txt`** (era opcional en el plan) como fuente de verdad de los mods,
   con `MOD_ID_PREFIX` en `.env` para poder cambiar el modo de prefijo sin tocar la lista.
6. **`Makefile` sin `backup` ni `restore`**: esas dos tareas son de la Fase 2 (necesitan `rclone` y
   el bucket). Se agregaron en cambio `status`, `dirs` y `mcrcon`.
7. **`servertest_spawnpoints.lua` también se copió al repo** (el plan solo mencionaba
   `_spawnregions.lua`); el server lo genera igual y conviene tenerlo versionado.
8. **`ServerPlayerID` y `ResetID` quedaron con los valores generados** dentro del `.tpl` a
   propósito: si cambian, los clientes son forzados a crear personaje nuevo. Versionarlos es lo que
   permite reconstruir la VM sin perder los personajes.
9. **`docker compose` no estaba instalado en `lucpc`** (solo el CLI de Docker). Se instaló el plugin
   en `~/.docker/cli-plugins/docker-compose` (v5.5.1), sin root. Anotado en el README.
10. **`shellcheck` y `mcrcon` no están empaquetados / no hay sudo sin password**: `shellcheck` se
    corrió con el contenedor `koalaman/shellcheck:stable` (los 5 scripts pasan limpio) y `mcrcon`
    0.7.2 se compiló desde fuente a `./bin/mcrcon` (gitignored, `make mcrcon` lo rehace).

#### Pendiente para el usuario

- **Tarea 10, la parte manual**: conectarse desde el cliente de Steam (B42 estable) a
  `127.0.0.1:16261` o a la IP LAN de `lucpc`, crear personaje, jugar un rato, y confirmar que
  después de `make down` + `make up` el personaje sigue ahí. Instrucciones paso a paso en el README.
- **Definir la partida antes de empezar en serio**: editar `config/servertest_SandboxVars.lua` y la
  lista de `config/mods.txt`, y recién ahí borrar `data/` y arrancar el mundo definitivo. Varias
  sandbox vars quedan fijadas al crear la partida.
- **Decidir `PVP`**: el `.tpl` quedó en `PVP=false` (co-op puro) como pedía el plan; si se quiere
  PvP opcional, `PVP=true` + `SafetySystem=true`.

### Cambio de enfoque (2026-09-03, decisión del usuario)

La PC local tiene recursos limitados y el usuario no quiere instalar el cliente de PZ en ella. Por lo tanto:
- La tarea 10 de Fase 1 (prueba con cliente Steam en local) **se cancela**. El server local se apagó y no se vuelve a usar salvo para probar scripts.
- La validación end-to-end se hace **en la nube con un amigo**: primer deploy con **partida limpia, sin mods** (`config/mods.txt` con todo comentado) y sandbox por defecto.
- Una vez validado: **wipe** (`scripts/wipe.sh`: stop limpio, backup final, borrar `Saves/Multiplayer/servertest` y el `db/`), definir `SandboxVars.lua` + `mods.txt` definitivos y arrancar la partida real.
- El repo necesita un remoto para que cloud-init lo clone en la VM: **repo privado en GitHub `lucbece/zomboid-server`** con deploy key de solo lectura generada por OpenTofu (pendiente de confirmación del usuario; alternativa sin GitHub: `make sync` que hace rsync del repo por SSH).
- La alerta de presupuesto de OCI se crea desde OpenTofu (`oci_budget_budget` + `oci_budget_alert_rule`), no a mano.

### Fase 2: nube, cloud-init, backups y runbook — **CÓDIGO LISTO 2026-09-03, `apply` pendiente**

Proveedor decidido: OCI Brazil East / São Paulo, `sa-saopaulo-1` (§4; el plan original decía Vinhedo, se cambió el 2026-09-03 al crear la cuenta).

Tareas:
1. [x] **`infra/cloud-init.yaml`**: Ubuntu 24.04, crear usuario `pz` con Docker, instalar `docker`, `docker compose`, `git`, `mcrcon`, `rclone`, `unattended-upgrades`; `git clone` de este repo a `/opt/zomboid-server`; escribir `.env` desde variables del cloud-init (o desde un secret del proveedor); instalar `infra/systemd/zomboid.service` (`ExecStart=make up`, `ExecStop=scripts/stop.sh`, `TimeoutStopSec=180`) y habilitarlo. Firewall (`ufw` o security list del proveedor): `16261-16262/udp` abierto, `22/tcp` y `27015/tcp` solo a la IP del admin.
2. [x] **OpenTofu** en `infra/terraform/` con el provider `oracle/oci`: compartment, VCN + subnet pública + internet gateway, security list (`16261-16262/udp` a todos, `22/tcp` y `27015/tcp` solo a la IP del admin), **IP pública reservada**, instancia `VM.Standard.E5.Flex` 4 OCPU / 16 GB con imagen Ubuntu 24.04 y boot volume 80 GB, bucket de Object Storage para backups, cloud-init como user-data. `envs/prod/` con `terraform.tfvars` gitignored. Salidas: IP reservada, comando SSH, string `IP:16261` para el juego. Prerrequisito manual: cuenta OCI con **home region São Paulo (`sa-saopaulo-1`)** (hecho 2026-09-03), upgrade a Pay As You Go (las cuentas free no pueden crear shapes E5 pagos) y alerta de presupuesto.
3. [x] **Backups**: `scripts/backup.sh` (RCON `save` → esperar 5 s → `tar` de `Saves/Multiplayer/servertest` + `Server/` → `rclone copy` a un bucket de object storage del proveedor, retención 14 días por nombre con fecha). Cron diario a las 06:00 hora local y siempre dentro de `stop.sh`. `scripts/restore.sh` documentado y **probado una vez** restaurando en un contenedor local.
4. [-] **DNS** (si hay dominio): registro A en Cloudflare apuntando a la IP reservada. Si el proveedor no da IP fija, script en boot que actualiza el registro con la API de Cloudflare.
5. [x] **`docs/runbook.md`**: conectar, ver jugadores, dar admin, reiniciar, agregar mods (flujo completo), actualizar el juego (`scripts/update.sh`: stop limpio, `compose pull`, up; el server también actualiza el juego al arrancar vía steamcmd), restaurar backup, qué hacer si "server has different version" o mismatch de mods (ver research 04 §6).
6. [x] **`scripts/wipe.sh`**: stop limpio → backup final etiquetado `pre-wipe` → borrar `data/zomboid/Saves/Multiplayer/servertest`, `data/zomboid/db/` y los backups nativos → confirmar interactivamente antes de borrar. Documentar en el runbook el flujo "partida de prueba → wipe → partida definitiva".
7. [x] **Presupuesto**: `oci_budget_budget` mensual (variable, default 25 USD) con `oci_budget_alert_rule` al 80% (FORECAST) y 100% (ACTUAL) al mail del admin.
8. [x] **Operación remota desde la PC del admin**: targets `make remote-status`, `remote-logs`, `remote-restart`, `remote-down`, `remote-rcon CMD=...` que hacen `ssh` a la VM y corren el Makefile allí; `make sync` (rsync de `config/` + `scripts/` + `Makefile` a la VM) para iterar config sin commitear.
9. [ ] Deploy real con partida limpia y sin mods; un amigo se conecta desde Argentina; medir ping, RAM/CPU (`docker stats`) y ajustar `MAX_MEMORY` y tamaño de VM.

Aceptación: `tofu apply` desde cero deja un server accesible en menos de 15 minutos; un amigo entra desde Argentina con ping < 60 ms; `tofu destroy` + `tofu apply` + `restore.sh` recupera el mundo; backup diario visible en el bucket; alerta de presupuesto visible en la consola de OCI.

#### Resultado de la Fase 2 (2026-09-03, en `lucpc`)

**Estado: todo el código escrito y validado sin credenciales. Falta el `tofu apply`** (la cuenta de
OCI recién se creó; ver "Pendiente para el usuario"). La aceptación de la fase se puede evaluar
recién después del deploy real (tarea 9).

Lo que quedó, con la validación que pasó cada cosa:

- **`infra/terraform/`** (`oracle/oci ~> 7.29` → 7.32.0, `hashicorp/tls ~> 4.1` → 4.4.0, pinneados
  en `.terraform.lock.hcl` que **sí** se commitea): `modules/oci/` + `envs/prod/`.
  `tofu init` + `tofu validate` → *Success! The configuration is valid.*; `tofu fmt -check
  -recursive` limpio. **No se corrió `plan` ni `apply`**: requieren `~/.oci/config`.
  - Compartment `zomboid`, VCN `10.0.0.0/16`, subnet pública `10.0.1.0/24`, internet gateway,
    route table.
  - **NSG** (no security list) con las reglas del plan. La security list default de la VCN se
    vacía con `oci_core_default_security_list`: como NSG y security list son **aditivos**, dejarla
    con su regla de 22/tcp abierta al mundo habría anulado el `admin_cidr`.
  - Instancia `VM.Standard.E5.Flex` con `assign_public_ip = false` en la VNIC y un
    `oci_core_public_ip` **RESERVED** atado a la private IP: así la IP sobrevive los stop/start de
    la Fase 3. Imagen por data source `oci_core_images` (Canonical Ubuntu 24.04, ordenado por
    `TIMECREATED DESC`), con `ignore_changes` sobre `source_id` para que la imagen nueva que
    Canonical publica cada mes no recree la VM sola.
  - Bucket `zomboid-backups` privado, versioning off, lifecycle rule DELETE a los 30 días.
  - `oci_identity_dynamic_group` (`ALL {instance.id = ...}`) + `oci_identity_policy` para que la VM
    escriba el bucket por **instance principal**: no hay ninguna credencial de OCI en la VM.
  - `oci_budget_budget` mensual (`budget_usd`, default 25) sobre el tenancy + alert rules FORECAST
    80% y ACTUAL 100%. Se puede desactivar con `enable_budget = false` si la cuenta no tiene
    permisos sobre el compartment raíz todavía.
  - Outputs: `public_ip`, `ssh_command`, `game_address` (`IP:16261`), `instance_ocid`,
    `bucket_name`, `bucket_namespace`, `deploy_public_key`.
- **`infra/cloud-init.yaml`**: template de `templatefile()`. Renderizado con valores de ejemplo y
  validado con `cloud-init schema --config-file` (cloud-init 26.1 en un contenedor `ubuntu:24.04`,
  no hay paquete en `lucpc` y no hay sudo) → *Valid schema*.
- **`infra/systemd/zomboid.service`**: `Type=oneshot` + `RemainAfterExit=yes`, `User=pz`,
  `ExecStart=/usr/bin/make up`, `ExecStop=scripts/stop.sh` con `WARN_SECONDS=30`,
  `TimeoutStopSec=200`. El shutdown de la VM dispara el `ExecStop` (save + quit).
- **Scripts nuevos**: `backup.sh`, `restore.sh`, `wipe.sh`, `update.sh`, `idle-shutdown.sh`,
  `cloud-start.sh`, `cloud-stop.sh` y `lib/oci-instance.sh`. Los 12 archivos de `scripts/` pasan
  `shellcheck` limpio (contenedor `koalaman/shellcheck:stable`).
- **`Makefile`**: `backup`, `restore FILE=`, `wipe`, `update`, `infra-{init,plan,apply,destroy}`,
  `remote-{status,logs,up,down,restart,rcon,backup}` y `sync`.
- **`docs/runbook.md`**: alta de la cuenta paso a paso, primer deploy, cómo entra un amigo,
  operación diaria, mods, update, backup/restore, wipe, Fase 3, costos y troubleshooting.

#### Desvíos respecto de lo planeado

1. **Región**: `sa-saopaulo-1` en vez de `sa-vinhedo-1` (§4, decisión del 2026-09-03).
2. **NSG en vez de security list** (el plan decía "security list"): los NSG se atan a la VNIC y no
   a la subnet, que es lo que corresponde para una sola VM. Además hubo que vaciar la security
   list default por lo aditivo de las reglas.
3. **Retención de backups: 30 días en el bucket** (el plan decía 14) porque así lo pidió la tarea, y
   3 días para las copias locales de la VM. La retención remota la hace la lifecycle rule de Object
   Storage, no el script.
4. **El `.env` de la VM se escribe primero en `/etc/zomboid/env`** y `runcmd` lo instala en
   `/opt/zomboid-server/.env` después del `git clone`: `git clone` se niega a clonar sobre un
   directorio que ya tiene archivos. El staging se borra con `shred`.
5. **`restore.sh` no se pudo probar end-to-end**: la prueba requiere levantar el server y el server
   local está apagado por decisión del usuario. Se probaron los caminos de error y la
   confirmación; la extracción y el `make up` quedan sin verificar.
6. **`idle-shutdown.sh` existe pero su línea de cron está comentada** en `/etc/cron.d/zomboid`:
   hasta que exista el bot de Discord de la Fase 3, apagar la VM sola dejaría a los amigos sin
   forma de prenderla.
7. **Tarea 4 (DNS) no aplica**: el usuario decidió no usar dominio (§4, decisión 3).
8. **`compartment` vacío en `rclone.conf`**: el backend `oracleobjectstorage` con
   `instance_principal_auth` resuelve el compartment desde el certificado de la instancia.
9. **`.terraform.lock.hcl` se sacó del `.gitignore`**: es el pin de versiones y hashes de los
   providers, tiene que estar versionado.

#### Pendiente para el usuario (Fase 2)

1. **Upgrade de la cuenta de OCI a Pay As You Go** y verificar el service limit de
   `VM.Standard.E5.Flex` en `sa-saopaulo-1` (runbook §1.2).
2. **Crear la API key y `~/.oci/config`** (runbook §1.3).
3. **Crear el repo privado `lucbece/zomboid-server` en GitHub y pushear `main`** (runbook §1.6).
4. **`cp terraform.tfvars.example terraform.tfvars`** y completar `tenancy_ocid`, `admin_cidr`
   (`curl -s https://ifconfig.me` + `/32`), `ssh_public_key`, `alert_email` y las tres passwords.
5. **`tofu apply -target=module.zomboid.tls_private_key.deploy`**, copiar el output
   `deploy_public_key` y cargarlo en GitHub como **deploy key de solo lectura** (runbook §1.7 y §2).
6. **`make infra-apply`** y esperar a que cloud-init termine (8-15 min por el pull de la imagen).
7. **Tarea 9**: entrar con un amigo desde Argentina, medir ping y `docker stats`, ajustar
   `MAX_MEMORY` si hace falta, y después `scripts/wipe.sh` para arrancar la partida definitiva.

### Fase 2.5: plantilla pública para terceros — **HECHA 2026-09-03** (falta pasar el repo a público)

Objetivo: que una persona sin experiencia técnica pueda levantar su propio server clonando este repo. El repo pasa a ser **público** una vez hecha esta fase y validado nuestro primer deploy con ella. Principio: **el camino feliz son 3 pasos** (crear cuenta OCI, `./setup.sh`, `make deploy`), y todo lo demás es opcional.

Tareas:
1. [x] **`setup.sh` (asistente interactivo, bash)**: chequea e instala prerrequisitos sin sudo (OpenTofu en `~/.local/bin`, `oci` CLI en un venv, `ssh-keygen` si no hay clave); detecta la IP pública del admin; pregunta con defaults sensatos (nombre del server, cantidad de jugadores, email para alertas, presupuesto mensual, región de OCI con lista de las cercanas); **genera passwords** seguras y legibles (tipo tres palabras + números) para admin, RCON y server, o acepta las que ponga el usuario; detecta el `repo_url` desde `git remote get-url origin`, verifica si es público con `git ls-remote` sin credenciales y elige clonado por HTTPS (sin deploy key) o SSH con deploy key; escribe `infra/terraform/envs/prod/terraform.tfvars` y `.env`; guía para crear la API key de OCI y valida `~/.oci/config` con `oci iam region list` o equivalente; es re-ejecutable (muestra los valores actuales como default).
2. [x] **`make deploy`**: orquesta el primer deploy end-to-end: `tofu init`, si hace falta deploy key: apply con `-target`, la sube con `gh repo deploy-key add` si `gh` está autenticado o imprime instrucciones y espera; `tofu apply`; espera SSH; sigue los logs de Docker del contenedor hasta `SERVER STARTED` (timeout 30 min); imprime un bloque final "Pasale esto a tus amigos" con IP, puerto y server password, y los comandos básicos. Idempotente: si ya está desplegado, solo actualiza.
3. [x] **`make doctor`**: preflight de prerrequisitos y diagnóstico (tofu, oci CLI y config válida, gh opcional, clave SSH, tfvars completo, estado de la VM si existe, últimos backups en el bucket). Mensajes en lenguaje simple con la acción a tomar.
4. [x] **`make destroy-all`** con confirmación fuerte: backup final, `tofu destroy`, recordatorio de que el bucket con backups queda y cómo borrarlo. Para que nadie quede pagando por olvido.
5. [x] **Cloud-init**: soportar clonado por HTTPS (sin deploy key) cuando `repo_url` empieza con `https://`; la deploy key solo se genera/inyecta si el repo es SSH. Variable `repo_url` con default al upstream público (quien no forkea igual puede usarlo: la config se ajusta con `make sync`).
6. [x] **Documentación para principiantes**: `README.md` reescrito como guía paso a paso en español (qué es esto, cuánto cuesta con números, requisitos: Linux/macOS o Windows con WSL, crear la cuenta OCI paso por paso con lo que se ve en pantalla, `./setup.sh`, `make deploy`, cómo entran los amigos, cómo agregar mods editando `config/mods.txt`, cómo cambiar reglas, cómo apagar todo). `README.en.md` versión corta en inglés. El runbook actual pasa a ser la referencia avanzada. Una sección "Problemas frecuentes" con los 8-10 errores más probables y su solución en lenguaje simple.
7. [x] **Genericizar**: sacar nombres propios (`Zomboid de los pibes`, `lucbece`, IPs de LAN) de ejemplos y defaults; `LICENSE` MIT; `CONTRIBUTING.md` corto; `.github/workflows/ci.yml` con shellcheck, `tofu fmt -check` + `validate`, validación de esquema de cloud-init y **gitleaks**; `.pre-commit-config.yaml` con gitleaks y shellcheck; plantilla de issue para "no puedo conectarme".
8. [ ] **Opcional si sobra tiempo**: `.devcontainer/devcontainer.json` con tofu + oci CLI para usar GitHub Codespaces desde cualquier SO, con advertencia clara de guardar `terraform.tfstate` (o `make state-backup` que lo sube cifrado al bucket).

Aceptación: en una carpeta limpia, `git clone` + `./setup.sh` + `make deploy` levanta el server sin tocar ningún archivo a mano; `make doctor` explica en una línea cada cosa que falta; CI verde; `gitleaks detect` sin hallazgos en todo el historial.

#### Resultado de la Fase 2.5 (2026-09-03, en `lucpc`)

**Estado: tareas 1 a 7 hechas.** La 8 (devcontainer / Codespaces) queda pendiente: es opcional y
arrastra el problema de dónde vive el `terraform.tfstate`, que merece su propia decisión.

Lo que quedó:

- **`setup.sh`** (raíz, ~500 líneas): asistente interactivo y re-ejecutable. Instala OpenTofu
  (checksum verificado) y el CLI `oci` (venv en `~/.venvs/oci`) sin sudo; guía el alta de la API
  key con el texto de lo que se ve en pantalla; detecta IP pública (`ifconfig.me` con fallback a
  `api.ipify.org`), clave SSH (y la crea si no hay) y `repo_url`; decide HTTPS vs deploy key
  probando `git ls-remote` con `GIT_CONFIG_GLOBAL=/dev/null` (para no usar el credential helper
  del usuario y que la prueba sea honesta); genera passwords `tres-palabras-1234` desde
  `scripts/lib/palabras.sh` (310 palabras ASCII, `/dev/urandom` con fallback a `$RANDOM`);
  escribe `terraform.tfvars` y `.env` con `umask 077`. Modo `--no-preguntar` con variables `ZS_*`
  para pruebas y CI. Los defaults salen de los archivos existentes, así que la segunda corrida
  solo cambia lo que se cambie.
- **`scripts/deploy.sh`** (`make deploy`): 7 pasos — `doctor -q` → `tofu init` → deploy key (solo
  si el repo es SSH; la sube con `gh repo deploy-key add` si `gh` está autenticado, si no imprime
  la clave y espera Enter) → plan + una sola confirmación (o `YES=1`) → espera SSH (10 min) →
  espera `SERVER STARTED` en `docker compose logs` mostrando la fase de cloud-init (30 min) → bloque
  "PASALE ESTO A TUS AMIGOS" + los 5 comandos. Idempotente. `DRY_RUN=1` imprime los pasos sin
  ejecutar nada.
- **`scripts/doctor.sh`** (`make doctor`): 20+ chequeos con `OK` / `AVISO` / `FALTA` y una línea
  de acción cada uno; `-q` para preflight (solo problemas, exit ≠ 0 si falta algo bloqueante).
- **`scripts/destroy-all.sh`** (`make destroy-all`): confirmación escribiendo el `public_name`,
  backup final por SSH si la VM responde, `tofu destroy`, y explicación de que el bucket y el
  compartment sobreviven si hay objetos + los comandos para borrarlos.
- **Cloud-init y OpenTofu**: `repo_url` acepta HTTPS o SSH. `local.use_deploy_key =
  !startswith(lower(trimspace(var.repo_url)), "https://")`; `tls_private_key.deploy` tiene
  `count`; el template usa `%{ if use_deploy_key ~}` para omitir `deploy_key`, `~/.ssh/config` y
  el `ssh-keyscan`. Default de `repo_url` = el upstream público. Nuevo output `use_deploy_key`.
- **`scripts/render-cloud-init.sh`**: renderiza el template en los dos modos (con una clave
  ed25519 de descarte generada al vuelo, para no dejar una clave privada escrita en el repo).
- **Docs**: `README.md` reescrito de cero como guía para principiantes; `README.en.md` corto;
  `docs/runbook.md` actualizado (HTTPS vs deploy key, `make deploy`/`doctor`/`destroy-all`, §8.1
  nueva, §12 con los dos modos); `CLAUDE.md` con los scripts nuevos y la regla de repo público.
- **Repo**: `LICENSE` (MIT), `CONTRIBUTING.md`, `.github/workflows/ci.yml` (shellcheck, tofu
  fmt/init/validate, cloud-init schema en los dos modos, gitleaks con `fetch-depth: 0`),
  `.pre-commit-config.yaml` y `.github/ISSUE_TEMPLATE/no-puedo-conectarme.yml`.

Validaciones que pasaron el 2026-09-03: `shellcheck -x` sobre `setup.sh` + los 16 scripts;
`tofu fmt -check -recursive` y `tofu validate`; `tofu plan -var-file` con el tfvars generado
(falla recién en el provider por falta de `~/.oci/config`, o sea que todas las `validation` de
variables pasan) en los dos modos, con `use_deploy_key = false` / `true` según corresponde;
`cloud-init schema` → *Valid schema* en los dos renders; `gitleaks detect` sobre los 15 commits
del historial → *no leaks found*; `setup.sh --no-preguntar` en un clon limpio.

#### Pendiente para el usuario (Fase 2.5)

1. **Pasar el repo a público** (o hacer el primer deploy con `repo_url` SSH y deploy key).
2. Validar el camino feliz completo con una cuenta de OCI real: `./setup.sh` → `make deploy`.
3. Opcional: tarea 8, `.devcontainer/` para Codespaces, decidiendo antes dónde vive el
   `terraform.tfstate` (hoy es local y está gitignoreado).

### Fase 3: on-demand y bot de Discord (obligatoria por decisión del usuario; ahorra ~85% del costo)

1. **Encendido/apagado manual**: `scripts/cloud-start.sh` / `cloud-stop.sh` con la CLI de OCI (`oci compute instance action --action START` / `--action SOFTSTOP`). `cloud-stop.sh` primero corre `stop.sh` por SSH (save + quit + backup) y después apaga la VM. En OCI la instancia Standard detenida no cobra cómputo.
2. **Apagado automático por inactividad**: cron en la VM cada 5 min que consulta `players` por RCON; si 0 jugadores durante 30 min ejecuta `stop.sh` y `shutdown -h now` (OCI deja la instancia en STOPPED). Umbral configurable en `.env`. Nunca apagar con jugadores conectados.
3. **Bot de Discord** (ver §4.1.b): Python con `discord.py` + SDK `oci`, en la instancia Always Free ARM de la misma tenancy. Comandos `/pz start|status|stop|restart|mods|backup`, con permisos por rol de Discord. Credenciales de OCI para el bot: usuario IAM dedicado con política mínima (`manage instances` sobre el compartment del juego) o Instance Principal si el bot corre en OCI. Anunciar IP y estado en el canal. Aceptación: un amigo sin acceso a nada más escribe `/pz start` y en menos de 3 minutos puede conectarse.
4. **Puente nativo de chat** (§4.1.a): `DiscordEnable`, `DiscordToken`, `DiscordChatChannel`, `DiscordLogChannel`, `DiscordCommandChannel` en el `.tpl`. Se puede hacer ya en Fase 1 si el bot de Discord se crea temprano.
5. **Actualización controlada de mods**: los mods del Workshop se actualizan solos al reiniciar; si un mod rompe la partida, fijar el proceso de rollback (quitar del ini, restaurar backup si hace falta). Considerar reinicio programado diario a una hora sin jugadores para tomar updates.

## 6. Riesgos y mitigaciones

- **B42 MP todavía madura** (desync al agacharse, culling de zombies; The Indie Stone dice que el hardening sigue). Mitigación: backups frecuentes, reinicio programado diario, seguir `projectzomboid.com/blog` para patches; los saves se conservan entre versiones 42.20.x.
- **Ecosistema de mods en flujo**: muchos forks paralelos "B42" del mismo mod. Mitigación: probar cada mod en local antes de subirlo a la partida real; anotar Workshop ID + Mod ID + fecha en `config/mods.txt`.
- **Costos de nube cambian** (Hetzner 2-3x, Oracle free tier a la mitad, ambos en junio 2026). Mitigación: on-demand, alertas de presupuesto en el proveedor, revisar precios antes de contratar.
- **Pérdida de saves por apagado sucio**. Mitigación: nunca `docker stop`/`kill` directo; todo pasa por `stop.sh`; backup en cada stop.
- **Secretos en git**. Mitigación: `.env` gitignored, ini se renderiza desde `.tpl`, `git-secrets` o hook opcional.

## 7. Cómo seguir

1. Decisiones de §4 tomadas (OCI São Paulo `sa-saopaulo-1`, on-demand, sin dominio, Discord).
2. ~~Ejecutar la Fase 1 en `lucpc`~~ **hecha el 2026-09-03** (ver "Resultado de la Fase 1").
3. ~~Fase 2.5: plantilla pública~~ **hecha el 2026-09-03**; falta pasar el repo a público y hacer el primer deploy con el camino nuevo (`./setup.sh` + `make deploy`).
4. Con el server funcionando, definir la partida: editar `config/servertest_SandboxVars.lua` y la lista de mods **antes** del primer arranque del mundo real.
5. Terminar la Fase 2 (tarea 9: deploy real y medición) y la Fase 3.
