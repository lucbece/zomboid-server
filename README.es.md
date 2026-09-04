# zomboid-server

*Read this in English: [README.md](README.md)*

Un servidor dedicado reproducible de **Project Zomboid Build 42**, ejecutado con Docker Compose.
Las reglas de la partida, la configuración del servidor y la lista de mods viven en `config/`
bajo control de versiones, así que el mismo mundo se puede reconstruir en cualquier máquina a
partir de este repositorio más un archivo de backup. La operación se hace con targets de `make`
que siempre apagan el juego de forma limpia por RCON, de modo que el mundo se guarda antes de que
el proceso termine.

Corre en cualquier máquina Linux con Docker: una PC que ya tengas, un servidor casero o un VPS.
El despliegue en un proveedor de nube es una opción soportada, no un requisito; ver
[Desplegar en un proveedor de nube](#desplegar-en-un-proveedor-de-nube).

## Características

- Servidor dedicado de Build 42 sobre una imagen fijada por digest: la versión del juego solo
  cambia cuando vos la cambiás.
- Reglas de la partida, puntos y regiones de aparición y configuración del servidor versionados
  en `config/`; los secretos quedan fuera de git, en `.env`.
- Mods del Workshop declarados en un único archivo de texto (`config/mods.txt`) que además define
  el orden de carga.
- Apagado y reinicio limpios: `save` + `quit` por RCON, nunca un `docker stop` a secas.
- Backups: un script que guarda el mundo y lo archiva, con subida opcional a almacenamiento de
  objetos, más procedimientos de restauración y de wipe.
- Auto-recuperación: un watchdog revisa el servidor cada dos minutos, se repone solo de las
  fallas comunes y avisa por Discord.
- Encuesta web opcional para que el grupo vote las reglas del sandbox antes de crear el mundo.
- Despliegue opcional en Oracle Cloud con OpenTofu en un comando, con IP pública reservada,
  backups diarios fuera de la máquina y alerta mensual de presupuesto.

## Requisitos

- Linux con Docker Engine y el plugin de Docker Compose. En Windows, usar WSL2.
- `make`, `bash` 4 o más nuevo, `git`, `gcc` (para compilar el cliente de RCON) y
  `gettext-base` para `envsubst`.
- Unos 15 GB de disco libre: la imagen del servidor pesa alrededor de 10,4 GB, más el mundo y los
  backups.
- RAM: el heap de la JVM se define con `MAX_MEMORY` en `.env`. 8 GB de heap alcanzan hasta 8
  jugadores; 12 GB, hasta 16. Dejá unos 4 GB por encima del heap para el sistema operativo y
  Docker.
- Cada jugador necesita Project Zomboid en Steam en la **rama estable (Build 42)**, sin ninguna
  beta seleccionada.

## Puesta en marcha

Ejecutar el servidor en una máquina Linux que ya tengas.

```bash
git clone https://github.com/lucbece/zomboid-server.git
cd zomboid-server
cp .env.example .env
```

Editá `.env` y definí al menos `ADMINPASSWORD`, `RCONPASSWORD` y `SERVER_PASSWORD`. Son tres
contraseñas distintas:

| Nombre en `.env` | Qué es |
|---|---|
| `SERVER_PASSWORD` | La **contraseña del servidor**. Es la que escriben los jugadores para entrar y la única que se reparte. |
| `ADMINPASSWORD` | La **contraseña de administrador** de la cuenta `admin` dentro del juego. No se comparte. |
| `RCONPASSWORD` | La **contraseña de RCON**, que usan los scripts de administración. Nunca se expone a los jugadores. |

Las contraseñas tienen que tener entre 8 y 64 caracteres y no pueden contener espacios, comillas,
barras invertidas ni `$`: `.env` lo leen tanto bash como Docker Compose, que no escapan igual.

Después, arrancar el servidor:

```bash
make mcrcon    # compila ./bin/mcrcon, el cliente de RCON que usan los scripts
make up        # renderiza config/ en el directorio de datos y levanta el contenedor
make logs      # el servidor está listo cuando imprime "*** SERVER STARTED ****"
```

El primer arranque descarga la imagen y genera el mundo; lleva varios minutos. Para apagar:

```bash
make down      # avisa a los jugadores, guarda por RCON y cierra
```

No apagues el contenedor con `docker stop` ni `docker kill`. El juego no maneja SIGTERM de forma
confiable y el mundo puede quedar en un estado inconsistente.

### Conectarse desde el juego

En Project Zomboid en la rama estable, sin ninguna beta de Steam seleccionada:

1. Menú principal → **Join**.
2. Pestaña **Favorites** → **Add server**.
3. Completar:
   - **Name**: cualquier etiqueta; es local a cada jugador.
   - **IP**: la dirección del servidor. En una red local, la dirección LAN de la máquina.
   - **Port**: `16261`.
   - **Account username** y **Account password**: las elige cada jugador. Se crean al entrar por
     primera vez y no son la contraseña del servidor.
   - **Server password**: el valor de `SERVER_PASSWORD`.
4. **Save** y después **Join**.

Para darle permisos de administrador dentro del juego a un jugador que ya entró al menos una vez:

```bash
make rcon CMD='setaccesslevel "nombre_del_jugador" admin'
```

## Configuración

Todo lo que está bajo `config/` es la fuente de verdad. Los archivos bajo `data/` son generados y
no se editan a mano: `make render` (que corren automáticamente `make up` y `make restart`) los
reescribe a partir de `config/` y `.env`.

| Archivo | Qué controla |
|---|---|
| `config/servertest.ini.tpl` | Configuración del servidor: PVP, jugadores máximos, visibilidad, chat, anticheat, backups nativos. Los secretos son placeholders que se completan desde `.env`. |
| `config/servertest_SandboxVars.lua` | Reglas de la partida: cantidad y comportamiento de los zombies, loot, clima, velocidad de aprendizaje, erosión. Cada valor está documentado en el propio archivo. |
| `config/servertest_spawnpoints.lua` | Dónde aparecen los personajes nuevos. |
| `config/servertest_spawnregions.lua` | Qué regiones de aparición se ofrecen. |
| `config/mods.txt` | Mods del Workshop, uno por línea; el orden del archivo es el orden de carga. |
| `.env` | Contraseñas, puertos, heap de la JVM, configuración de backups. No está en git. |

Los cambios de configuración se aplican con:

```bash
make restart
```

Nota: varias opciones del sandbox quedan fijadas al generar el mundo, entre ellas el tamaño del
mapa de loot, la población inicial de zombies y la velocidad de erosión. Cambiarlas después no
tiene efecto sobre un mundo existente. Conviene definirlas antes de la primera partida en serio, o
empezar un mundo nuevo con `make wipe`.

Dos claves de `config/servertest.ini.tpl` no deberían cambiarse en un mundo en curso:
`ServerPlayerID` y `ResetID`. Si cambian, todos los clientes son forzados a crear un personaje
nuevo. Están versionadas justamente para que un servidor reconstruido conserve la misma
identidad.

Por defecto la plantilla usa `Public=true`, así que el servidor aparece en el navegador de
servidores del juego y queda protegido por la contraseña del servidor. Poné `Public=false` si
preferís que solo se pueda llegar por IP directa.

### Mods

Agregá una línea a `config/mods.txt` con el Workshop ID y el Mod ID, y después `make restart`:

```
3750253491  VB_CommonSense  # Common Sense
```

Sacar un mod de un mundo que ya contiene sus objetos o sus celdas de mapa puede corromper el
save. Hacé un backup antes. El procedimiento completo, incluido cómo leer las dependencias
`require=` de un mod y cómo diagnosticar uno que no carga, está en [`docs/mods.md`](docs/mods.md).

## Operación

| Comando | Qué hace |
|---|---|
| `make up` | Renderiza la configuración y levanta el servidor |
| `make down` | Apagado limpio: aviso, `save`, `quit` |
| `make restart` | Apagado limpio, re-render y arranque; es la forma de aplicar cambios de configuración y de mods |
| `make logs` | Sigue el log del servidor |
| `make status` | Estado del contenedor y jugadores conectados |
| `make rcon CMD=players` | Ejecuta cualquier comando de administración por RCON |
| `make backup` | `save`, archiva el mundo y lo sube si hay un bucket configurado. `LABEL=` agrega un sufijo |
| `make restore FILE=…` | Restaura un archivo sobre el mundo actual |
| `make wipe` | Borra el mundo después de un backup `pre-wipe`. Pide confirmación |
| `make update` | Backup, apagado limpio, `docker compose pull` y arranque |
| `make render` | Regenera la configuración renderizada sin reiniciar |
| `make mcrcon` | Compila el cliente de RCON en `./bin/mcrcon` |

`make help` lista todos los targets, incluidos los de nube.

### Backups

`make backup` ejecuta `save` por RCON, archiva `Saves/Multiplayer/servertest`, `Server/` y `db/`
en `backups/` como un `.tar.zst`, y lo copia a almacenamiento de objetos cuando `BACKUP_BUCKET`
está definido en `.env`. Los archivos locales más viejos que `BACKUP_KEEP_LOCAL_DAYS` se borran.
También funciona con el servidor apagado, en cuyo caso se saltea el paso de `save`.

Los backups rotativos propios del juego se configuran en `config/servertest.ini.tpl`
(`BackupsCount`, `BackupsPeriod`, `BackupsOnStart`) y quedan en `data/zomboid/backups/`. Son una
red de seguridad de corto plazo, no un reemplazo de las copias fuera de la máquina.

Restaurar pide confirmación, apaga el servidor, archiva el mundo actual como `pre-restore` y
recién entonces extrae el archivo elegido:

```bash
make restore FILE=backups/zomboid-20260903-0600.tar.zst
```

### Actualizar el juego

La imagen está fijada por digest en `docker-compose.yml`, así que nada se actualiza solo. Para
pasar a una compilación más nueva, resolvé el digest del tag que quieras, editá
`docker-compose.yml` y ejecutá `make update`. Una imagen nueva puede traer una versión nueva del
juego; los clientes que estén en la anterior van a ser rechazados hasta que Steam los actualice.
El procedimiento está en [`docs/runbook.md`](docs/runbook.md).

## Exponer el servidor desde una red hogareña

El servidor escucha en UDP `16261` y `16262`. RCON escucha en TCP `27015` y está atado a
`127.0.0.1`, así que no es alcanzable desde fuera del host.

Para que tus amigos se conecten a una máquina de tu red hogareña:

1. Asignale a la máquina una dirección fija en la LAN, o una reserva de DHCP.
2. Redirigí UDP `16261-16262` desde el router hacia esa dirección. No redirijas `27015`.
3. Pasá tu IP pública y la contraseña del servidor.

Dos advertencias. La mayoría de las conexiones hogareñas tienen IP pública dinámica, así que la
dirección cambia cada tanto; un nombre de DNS dinámico evita tener que reenviarla cada vez. Y las
conexiones detrás de CGNAT no tienen ninguna dirección pública redirigible. En los dos casos la
solución habitual es un servicio de túnel o una red superpuesta (Tailscale, ZeroTier, Cloudflare
Tunnel y similares); este repositorio no configura ninguno.

## Desplegar en un proveedor de nube

Si preferís no correr el servidor en tu casa, el repositorio puede aprovisionar una máquina
virtual y configurarla de punta a punta. **Oracle Cloud** es el proveedor soportado hoy, por tres
razones: tiene región en São Paulo, una instancia detenida no factura cómputo, y sus direcciones
IP públicas reservadas son gratuitas, así que la dirección sobrevive a los ciclos de apagado y
encendido.

Dos comandos, una vez que existe la cuenta de Oracle Cloud:

```bash
./setup.sh      # asistente interactivo: revisa herramientas, genera contraseñas, escribe la configuración
make deploy     # crea la infraestructura y espera a que el juego esté arriba
```

`setup.sh` dimensiona la máquina según la cantidad de jugadores que declares: hasta 8 jugadores
elige 2 OCPU / 12 GB con 8 GB de heap; por encima de eso, 4 OCPU / 16 GB con 12 GB de heap.
`ZS_OCPUS` y `ZS_MEMORY_GB` permiten forzar otros valores.

Precios de lista aproximados del shape `VM.Standard.E5.Flex` a 2026-09 (0,03 USD por OCPU-hora y
0,002 USD por GB-hora). Verificalos antes de contratar: los precios cambian, y los impuestos
locales sobre servicios digitales del exterior se cobran aparte.

| Tamaño de la VM | Jugadores | Por hora | ~20 h/semana | ~6 h/día | 24/7 |
|---|---|---|---|---|---|
| 2 OCPU / 12 GB | hasta 8 | 0,084 USD | ~7 USD/mes | ~15 USD/mes | ~61 USD/mes |
| 4 OCPU / 16 GB | hasta 16 | 0,152 USD | ~13 USD/mes | ~28 USD/mes | ~111 USD/mes |

El disco de arranque de 80 GB cuesta unos 2 USD por mes y se factura esté la máquina prendida o
apagada. Los backups en almacenamiento de objetos cuestan centavos. La IP reservada es gratuita.

Nota: una VM encendida se factura haya o no jugadores conectados. Apagala con
`./scripts/cloud-stop.sh`, que guarda el mundo, hace un backup y detiene la instancia;
`./scripts/cloud-start.sh` la vuelve a encender con la misma dirección. `make destroy-all` borra
todo y corta cualquier cargo.

El alta de la cuenta, las claves de API, el recorrido completo del despliegue, el detalle de
costos y los problemas propios de Oracle están en
[`docs/deploy-oracle.md`](docs/deploy-oracle.md).

### Otros proveedores

El código de Terraform está organizado como `infra/terraform/modules/<proveedor>` con un entorno
delgado en `infra/terraform/envs/prod`, así que se puede agregar otro proveedor como módulo
hermano. Un módulo nuevo tiene que aportar: una VM Ubuntu 24.04 con dirección pública, ingreso
UDP 16261-16262 desde cualquier origen y TCP 22 restringido al administrador, el archivo
`infra/cloud-init.yaml` renderizado como user data y, opcionalmente, un bucket de almacenamiento
de objetos más las credenciales para subir los backups. El propio cloud-init es neutral respecto
del proveedor.

## Encuesta de reglas

`tools/encuesta/` es una pequeña encuesta web autohospedada que permite a un grupo votar las
reglas del sandbox antes de crear el mundo. Sirve una página apta para el celular, registra una
línea JSON por voto, cuenta los resultados y puede escribir las opciones ganadoras directamente
en `config/`. Es opcional y está desactivada por defecto. Ver [`docs/survey.md`](docs/survey.md),
incluidas las consideraciones de seguridad de exponerla por HTTP sin cifrar.

## Panel de moderadores

`tools/panel/` es una página web opcional para que dos a cuatro personas de confianza puedan
reiniciar el servidor del juego sin cuenta de SSH: muestra el estado del server y quién está
conectado, y ofrece un solo botón que hace el mismo reinicio limpio que `make restart`. Cada
moderador recibe su propio link, que es además su credencial, y los reinicios tienen cooldown y
quedan registrados. Es opcional y está desactivado por defecto. Ver
[`docs/panel.md`](docs/panel.md), incluido el modelo de seguridad de repartir una URL sin
autenticación por HTTP sin cifrar.

## Auto-recuperación

Un timer de systemd corre `scripts/watchdog.sh` cada dos minutos en la VM. Revisa la unit, el
contenedor, RCON, el log y el espacio libre en disco; cuando algo anda mal aplica un playbook
fijo —un reinicio limpio, o un apagado con bundle de diagnóstico y arranque, o una limpieza de
disco— y publica el resultado en un canal de Discord si `DISCORD_WEBHOOK_URL` está configurada.
Tiene un tope de dos reinicios automáticos por hora, y nunca hace wipe ni restore, no borra
partidas ni toca `config/`. Cuando el playbook no alcanza, escala: a una persona por defecto, o
—opcionalmente— a Claude Code corriendo headless en la máquina con un conjunto de herramientas
deliberadamente angosto. Ver [`docs/self-healing.md`](docs/self-healing.md): qué detecta, qué no
hace nunca, cómo crear el webhook de Discord y los riesgos de la segunda capa.

```bash
make watchdog-install    # instala y habilita el timer en una VM que ya existe
make watchdog-status     # próxima corrida, último resultado, final del log
make remote-diff         # qué cambió el auto-arreglo en la VM y sigue sin commitear
```

## Discord

Dos integraciones independientes, y cualquiera de las dos se puede dejar apagada. El puente de
chat del propio juego espeja el chat global en un canal y necesita un bot con el intent de
Message Content; viene apagado. Los avisos de estado son un daemon chico de systemd en la VM que
publica en un webhook cuando el server queda activo, cuando se apaga y cuando entra o sale
alguien —el mensaje de "servidor activo" trae la dirección, el puerto, la password del server, la
cantidad de mods y la versión del juego, así nadie tiene que preguntar—. Comparte
`DISCORD_WEBHOOK_URL` con el watchdog, agrupa los eventos en una ventana de 30 segundos y se
queda callado si no hay webhook configurada. Poner la password en un canal es una decisión:
`NOTIFIER_INCLUDE_PASSWORD=0` la deja afuera. Ver [`docs/discord.md`](docs/discord.md): las dos
integraciones, cómo crear el webhook y cómo se leen las entradas y salidas de los logs del juego.

```bash
make notifier-install    # instala y habilita el daemon en una VM que ya existe
make notifier-status     # estado de la unit y las últimas 20 líneas del journal
```

## Documentación

| Documento | Contenido |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Cómo encajan las piezas y las decisiones vigentes |
| [`docs/runbook.md`](docs/runbook.md) | Referencia de operación: despliegue, backups, wipes, actualizaciones, diagnóstico |
| [`docs/deploy-oracle.md`](docs/deploy-oracle.md) | Despliegue en Oracle Cloud: cuenta, clave de API, `setup.sh`, `make deploy`, costos |
| [`docs/mods.md`](docs/mods.md) | Agregar, quitar y diagnosticar mods del Workshop |
| [`docs/survey.md`](docs/survey.md) | La encuesta de reglas: cómo levantarla, contarla y cerrarla |
| [`docs/panel.md`](docs/panel.md) | El panel de moderadores: tokens, cooldowns, modelo de seguridad (en inglés) |
| [`docs/self-healing.md`](docs/self-healing.md) | El watchdog, los avisos de Discord y el auto-arreglo opcional con Claude Code (en inglés) |
| [`docs/discord.md`](docs/discord.md) | Las dos integraciones con Discord: el puente de chat nativo y los avisos de estado (en inglés) |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Qué verificar antes de abrir un pull request |
| [`docs/history/`](docs/history/) | El plan original y las notas de investigación, en castellano. Material histórico, sin mantenimiento |

La documentación se escribe en inglés; este archivo es su traducción completa.

## Licencia

[MIT](LICENSE). Project Zomboid es un producto de The Indie Stone; este proyecto no tiene relación
con ellos.
