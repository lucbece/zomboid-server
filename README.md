# Tu propio servidor de Project Zomboid

*[English version](README.en.md) · Guía completa en castellano*

Esto es una receta para armar **tu propio servidor de Project Zomboid (Build 42)** en internet,
para jugar con amigos, sin depender de ningún servicio de hosting.

No hace falta saber programar. Son tres pasos, y las computadoras hacen el resto:

```bash
git clone https://github.com/lucbece/zomboid-server.git && cd zomboid-server
./setup.sh      # te pregunta cuatro cosas y prepara todo
make deploy     # crea el servidor (una vez; tarda entre 20 y 40 minutos)
```

Cuando termina, te muestra la IP y la contraseña que le tenés que pasar a tus amigos.

## Qué obtenés

- Un servidor dedicado para **8 a 16 jugadores**, prendido las 24 horas si querés.
- Una **IP fija** que no cambia nunca: tus amigos la guardan como favorito y listo.
- **Copias de seguridad automáticas** todos los días, guardadas fuera de la máquina.
- **Mods** del Workshop: se agregan editando un archivo de texto.
- Todas las reglas de la partida en archivos que podés versionar y compartir.
- Un aviso por mail si el gasto del mes se pasa de lo que vos digas.
- Apagado limpio siempre: el mundo se guarda antes de cerrar, nunca se pierde progreso.

Lo que **no** es: no es un servicio administrado. La máquina es tuya, la tarjeta es tuya, y si
la dejás prendida sin jugar, pagás igual. La última sección de esta guía explica cómo apagar
todo en un comando.

---

## Cuánto cuesta

El servidor corre en **Oracle Cloud**. Se paga por hora de máquina prendida.

| Cómo lo usás | Qué pagás por mes | Para quién |
|---|---|---|
| **Siempre prendido** (24/7) | **~90 USD** | Grupos grandes que juegan a cualquier hora y quieren que el mundo esté siempre disponible |
| **Lo prendés cuando juegan** (~20 h por semana) | **~11 a 15 USD** | Lo normal para un grupo de amigos |

En los dos casos hay un costo fijo chico que **se paga aunque la máquina esté apagada**:

- **Disco: 2 a 3 USD por mes.** Es donde vive el mundo. Solo desaparece si borrás todo.
- Copias de seguridad: unos centavos (0,03 USD por GB por mes).
- La IP fija: gratis.

Para prender y apagar a mano:

```bash
./scripts/cloud-stop.sh    # guarda la partida, hace una copia y apaga la máquina
./scripts/cloud-start.sh   # la prende de nuevo; la IP es la misma de siempre
```

> Como referencia: un hosting administrado de Project Zomboid cuesta entre 24 y 48 USD por mes.
> Si no querés operar nada y el server va a estar siempre prendido, puede convenirte. Este repo
> tiene sentido si querés controlar la máquina, los backups y los mods vos mismo, o si vas a
> jugar por ratos.

**Antes de empezar, Oracle te va a pedir una tarjeta de crédito.** Es normal: hace una retención
de aproximadamente 1 USD que después devuelve. Igual, configurá el aviso de gasto que te propone
`./setup.sh` (viene en 25 USD por defecto).

---

## Qué necesitás

1. **Una computadora con Linux o macOS.**
   Si usás **Windows**, hace falta WSL2 (es Linux adentro de Windows, gratis y oficial). Abrí
   PowerShell **como administrador** y corré:

   ```powershell
   wsl --install -d Ubuntu
   ```

   Reiniciá, abrí "Ubuntu" desde el menú Inicio, creá tu usuario, y a partir de ahí seguí esta
   guía adentro de esa ventana como si fuera Linux.

2. **Una tarjeta de crédito** para la cuenta de Oracle Cloud.

3. **Una cuenta de GitHub: opcional.** Si solo querés levantar el server tal cual, no hace falta.
   Solo la vas a necesitar si querés guardar tus propias reglas y tu lista de mods (ver
   [Hacer que la configuración sea tuya](#hacer-que-la-configuración-sea-tuya)).

4. **Project Zomboid comprado en Steam**, vos y cada uno de tus amigos. La versión tiene que ser
   la **estable (Build 42)**, que es la que Steam instala por defecto.

Las demás herramientas (OpenTofu, el programa de Oracle) las instala `./setup.sh` solo, sin
pedirte contraseña de administrador.

---

## Paso 1: crear la cuenta de Oracle Cloud

Esto es lo único que se hace en la web y lo único que lleva un rato. Reservate 20 minutos.

### 1.1 Registrarte

1. Entrá a <https://www.oracle.com/cloud/free/> y creá la cuenta.
2. **Prestá atención a la "Home Region"**: es dónde va a vivir tu servidor y **no se puede
   cambiar después**. Elegí la más cercana a donde viven los jugadores:

   | Si los jugadores están en... | Elegí | Ping aproximado |
   |---|---|---|
   | Argentina, Uruguay, Chile, Brasil | **Brazil East (São Paulo)** | ~30 ms |
   | Argentina o Chile (alternativa) | Chile Central (Santiago) | ~25-35 ms |
   | Estados Unidos, costa este | US East (Ashburn) | ~20 ms |
   | Estados Unidos, costa oeste | US West (Phoenix) | ~20 ms |
   | España | Spain Central (Madrid) | ~20 ms |
   | Resto de Europa | Germany Central (Frankfurt) | ~20 ms |
   | Reino Unido | UK South (London) | ~15 ms |

3. Verificá el mail y cargá la tarjeta.
4. **Esperá el mail que dice que la cuenta está lista** ("Your Oracle Cloud Account is ready" o
   similar). Puede tardar entre 10 minutos y algunas horas. Hasta que llegue, no sigas.

### 1.2 Pasar la cuenta a "Pay As You Go"

La cuenta gratuita **no puede crear** la máquina que hace falta: el deploy falla con un error de
límites. Hay que convertirla a cuenta paga (que igual solo cobra lo que usás).

En la consola de Oracle: arriba a la derecha, menú de la cuenta → **Upgrade to Paid** (o
*Billing & Cost Management* → *Upgrade and Payment*). Tarda unos minutos en aplicarse.

### 1.3 Crear la llave de acceso (API key)

Es lo que le permite a tu computadora crear cosas en tu cuenta. Suena técnico, pero es
copiar y pegar:

1. En la consola de Oracle, arriba a la derecha, **ícono de la persona** → **My profile**.
2. Menú de la izquierda → **API keys** → botón **Add API key**.
3. Dejá marcado **Generate API key pair** y apretá **Download private key**. Se te baja un
   archivo `.pem`. Guardalo, es tu llave.
4. Apretá **Add**. Oracle te muestra un cuadro de texto con cuatro líneas
   (`user=`, `fingerprint=`, `tenancy=`, `region=`). **Copialo entero.**
5. En tu terminal (la de Ubuntu si estás en Windows):

   ```bash
   mkdir -p ~/.oci && chmod 700 ~/.oci
   mv ~/Descargas/*.pem ~/.oci/oci_api_key.pem     # o ~/Downloads, según tu sistema
   chmod 600 ~/.oci/oci_api_key.pem
   nano ~/.oci/config
   ```

6. Pegá el cuadro que copiaste (en nano se pega con clic derecho o Ctrl+Shift+V) y **agregá al
   final una línea más**, con tu nombre de usuario en lugar de `TU_USUARIO`:

   ```
   key_file=/home/TU_USUARIO/.oci/oci_api_key.pem
   ```

   El archivo entero tiene que quedar así:

   ```ini
   [DEFAULT]
   user=ocid1.user.oc1..aaaa...
   fingerprint=aa:bb:cc:...
   tenancy=ocid1.tenancy.oc1..aaaa...
   region=sa-saopaulo-1
   key_file=/home/TU_USUARIO/.oci/oci_api_key.pem
   ```

7. Guardá con **Ctrl+O**, Enter, **Ctrl+X**, y protegé el archivo:

   ```bash
   chmod 600 ~/.oci/config
   ```

Si algo de esto salió mal, no importa: `./setup.sh` te lo va a decir con todas las letras y te
deja volver a intentar.

---

## Paso 2: `./setup.sh`

En tu terminal:

```bash
git clone https://github.com/lucbece/zomboid-server.git
cd zomboid-server
./setup.sh
```

El asistente:

- revisa que estén las herramientas y **te ofrece instalar las que falten** (sin pedirte
  contraseña de administrador);
- **inventa las contraseñas por vos**, del tipo `arena-tulipan-molino-4821`: fáciles de dictar
  por Discord y difíciles de adivinar;
- detecta tu IP de internet, tu llave de acceso y tu región;
- te pregunta cuatro cosas: nombre del server, cuántos jugadores, tu mail para los avisos de
  gasto, y a partir de cuántos dólares avisarte.

En todas las preguntas podés apretar Enter para aceptar lo que propone.

**Se puede volver a correr las veces que quieras.** La segunda vez te muestra lo que ya elegiste
y solo cambia lo que cambies. Útil, por ejemplo, cuando tu proveedor de internet te cambia la IP.

Para ver si quedó todo en orden:

```bash
make doctor
```

Cada línea dice `OK`, `AVISO` o `FALTA`, y debajo de cada `FALTA` está exactamente qué hacer.

---

## Paso 3: `make deploy`

```bash
make deploy
```

Te muestra la lista de lo que va a crear, te avisa que a partir de ahí se empieza a cobrar, y
pide confirmación **una sola vez**. Después no te pregunta nada más.

Tarda entre **20 y 40 minutos la primera vez**: la máquina se prende, instala todo y baja el
juego entero (unos 10 GB). Vas viendo en qué está. Podés dejarlo corriendo e irte a hacer otra
cosa; si cortás con Ctrl+C no rompés nada, y volvés a entrar con `make deploy` cuando quieras.

Cuando termina, te muestra un bloque como este:

```
   PASALE ESTO A TUS AMIGOS

     Nombre .................. Mi server de Zomboid
     IP ...................... 150.230.x.y
     Puerto .................. 16261
     Contraseña del server ... arena-tulipan-molino-4821
```

`make deploy` se puede correr todas las veces que quieras: si ya está todo creado, no cambia
nada y te vuelve a mostrar esos datos.

---

## Cómo entran tus amigos

En Project Zomboid, con la versión estable (Build 42, **sin** ninguna beta activada en Steam):

1. Menú principal → **Join**.
2. Pestaña **Favorites** → botón **Add server** (abajo).
3. Completar:
   - **Name**: lo que quieran, es solo para ellos.
   - **IP**: la que les pasaste.
   - **Port**: `16261`.
   - **Account username** y **Account password**: **las eligen ellos**, son suyas y se crean
     solas la primera vez que entran. No son la contraseña del server.
   - **Server password**: la contraseña del server que les pasaste.
4. **Save** y después **Join**.

El server no aparece en la lista pública de servidores a propósito: solo entra quien tenga la IP
y la contraseña.

Para darte a vos (o a un amigo) poderes de administrador dentro del juego, una vez que entraron
por primera vez con su usuario:

```bash
make remote-rcon CMD='setaccesslevel "tu_usuario" admin'
```

---

## Los 5 comandos del día a día

| Comando | Qué hace |
|---|---|
| `make remote-status` | ¿Está arriba? ¿Quién está jugando? |
| `make remote-logs` | Ver qué está pasando en vivo (Ctrl+C para salir) |
| `make remote-restart` | Reiniciar con aviso a los jugadores: aplica cambios de mods y reglas |
| `make remote-backup` | Guardar una copia de la partida ahora mismo |
| `make destroy-all` | Borrar todo y dejar de pagar |

Y dos más que vas a usar seguido:

| Comando | Qué hace |
|---|---|
| `make sync RESTART=1` | Subir tus cambios de configuración al server y reiniciarlo |
| `make doctor` | Revisar que esté todo bien y qué falta |

---

## Agregar mods

1. Buscá el mod en el Workshop de Steam. Necesitás **dos identificadores**:
   - el **Workshop ID**: el número que aparece en la URL, después de `?id=`.
     Por ejemplo, en `steamcommunity.com/sharedfiles/filedetails/?id=3750253491` es
     `3750253491`.
   - el **Mod ID**: un nombre corto sin espacios. Casi siempre está escrito en la descripción
     del mod, en una línea que dice `Mod ID: VB_CommonSense`. Si no está, `make remote-logs`
     lo muestra cuando el server intenta cargarlo.

2. Agregá una línea a `config/mods.txt`, en el orden en que querés que carguen:

   ```
   3750253491  VB_CommonSense  # Common Sense
   ```

3. Subilo al server y reiniciá:

   ```bash
   make sync RESTART=1
   ```

Tus amigos no tienen que hacer nada: el juego les baja los mods solo cuando se conectan.

Para sacar un mod, borrá o comentá la línea (poniéndole un `#` adelante) y `make sync RESTART=1`.
**Sacar un mod de una partida en curso puede romper el mundo** (desaparecen objetos y recetas que
ya existían): hacé `make remote-backup` antes.

Más detalle: [`docs/mods.md`](docs/mods.md).

---

## Cambiar las reglas de la partida

Las reglas (cantidad de zombies, si corren, cuánto loot hay, clima, velocidad de aprendizaje…)
están en `config/servertest_SandboxVars.lua`. Está lleno de comentarios que explican cada valor.

```bash
nano config/servertest_SandboxVars.lua
make sync RESTART=1
```

> **Definí las reglas ANTES de empezar la partida en serio.** Varias opciones —el tamaño del
> mapa de loot, la población inicial de zombies, la velocidad de erosión— quedan grabadas cuando
> el mundo se crea, y cambiarlas después no tiene efecto.

Si ya empezaste y querés arrancar de cero con las reglas nuevas:

```bash
ssh USUARIO@TU_IP 'cd /opt/zomboid-server && ./scripts/wipe.sh'
```

`wipe.sh` guarda una copia de seguridad de la partida vieja antes de borrarla, y te pide escribir
`wipe` para confirmar. (`make deploy` te muestra el usuario y la IP; el usuario es `pz`.)

Otras cosas que podés ajustar: PVP, cantidad máxima de jugadores, chat y anticheat, en
`config/servertest.ini.tpl`. Dónde aparecen los jugadores nuevos, en
`config/servertest_spawnpoints.lua`.

---

## Copias de seguridad

Hay tres capas, y no tenés que hacer nada para que funcionen:

1. El propio juego guarda una copia cada hora y en cada arranque.
2. **Todos los días a las 6 de la mañana** se hace una copia completa y se sube a la nube,
   fuera de la máquina del server. Se guardan 30 días.
3. Cada vez que se apaga o reinicia el server, se guarda el mundo antes de cerrar.

Copia manual, cuando vas a hacer algo arriesgado:

```bash
make remote-backup
```

Volver atrás a una copia:

```bash
ssh pz@TU_IP
cd /opt/zomboid-server
rclone lsl oci:zomboid-backups                      # lista las copias disponibles
./scripts/restore.sh oci:zomboid-backups/ARCHIVO.tar.zst
```

Te pide confirmación, apaga el server, guarda una copia de lo que hay ahora (por las dudas) y
restaura la que elegiste.

---

## Apagar todo y dejar de pagar

**Para dejar de pagar por unos días o semanas** (el mundo se conserva; seguís pagando el disco,
2-3 USD por mes):

```bash
./scripts/cloud-stop.sh     # guarda, copia y apaga
./scripts/cloud-start.sh    # lo vuelve a prender, con la misma IP
```

**Para borrar todo y no pagar nada más**:

```bash
make destroy-all
```

Antes de borrar guarda una última copia de la partida en la nube, te pide escribir el nombre de
tu server para confirmar, y al final te explica qué quedó (solo las copias de seguridad, que son
centavos) y cómo borrarlo también si querés no dejar rastro.

---

## Hacer que la configuración sea tuya

Podés usar este repo tal cual: la máquina baja la configuración de acá y con `make sync` le
mandás tus cambios locales. Funciona perfecto, pero si un día recreás la máquina, tus mods y tus
reglas no vuelven solos.

Para que la configuración sea realmente tuya y sobreviva a todo:

1. Entrá a <https://github.com/lucbece/zomboid-server> y apretá **Fork** (arriba a la derecha).
2. En tu computadora, apuntá el repo a tu copia y subí tus cambios:

   ```bash
   git remote set-url origin https://github.com/TU_USUARIO/zomboid-server.git
   git add config/ && git commit -m "mis mods y mis reglas" && git push
   ./setup.sh      # detecta el repo nuevo
   make deploy
   ```

Si dejás tu fork **público**, no hay ningún paso extra. Si lo hacés **privado**, `make deploy` se
encarga de darle permiso de lectura a la máquina (te lo pide una vez, o lo hace solo si tenés la
herramienta `gh` de GitHub instalada y conectada).

---

## Problemas frecuentes

**1. "Server has different version than client"**
El juego de tu amigo está en otra versión. En Steam: clic derecho en Project Zomboid →
Propiedades → **Betas** → tiene que estar en **None**. Después dejá que Steam actualice.

**2. Mis amigos no pueden entrar y yo sí**
Casi siempre están poniendo mal el puerto (tiene que ser **16261**) o están escribiendo su
contraseña de cuenta donde va la del server. Revisá con ellos los campos del formulario.

**3. Yo no puedo entrar y ellos sí, o `make remote-status` no anda**
Cambió tu IP de internet (pasa solo, cada tanto). Solución:

```bash
./setup.sh      # detecta la IP nueva, Enter a todo
make deploy     # aplica el cambio, no toca la partida
```

**4. `make deploy` falla con `LimitExceeded` o `NotAuthorizedOrNotFound`**
Casi siempre es una de dos: la cuenta de Oracle todavía es gratuita (hay que pasarla a *Pay As
You Go*, paso 1.2) o la región que elegiste no es la misma que la de tu cuenta. `make doctor` te
dice cuál de las dos es.

**5. `make deploy` dice que Oracle no acepta la clave**
Algo quedó mal en `~/.oci/config`. Revisá que la primera línea sea exactamente `[DEFAULT]` y que
la línea `key_file=` apunte al archivo `.pem` que bajaste, con la ruta completa. Para ver el
error real: `oci iam region-subscription list`.

**6. Pasaron 40 minutos y el juego no arranca**
Mirá qué está haciendo: `make remote-logs`. Si dice `Permission denied (publickey)`, la máquina
no puede bajar tu repo privado: corré `make deploy` otra vez y cargá la llave que te muestra.
Si simplemente está bajando cosas, esperá: son 10 GB.

**7. "You have different mods" / "Checksum mismatch"**
Tu amigo tiene una versión distinta de un mod. Que se desuscriba y se vuelva a suscribir en el
Workshop, y que borre la carpeta `Zomboid/Workshop` de su computadora. Si sigue, reiniciá el
server con `make remote-restart` para que tome la versión nueva del mod.

**8. Agregué un mod y ahora el server no arranca**
Sacá la línea del mod de `config/mods.txt`, `make sync RESTART=1`. Si el mundo quedó dañado,
restaurá la última copia buena (sección "Copias de seguridad").

**9. Se cortó la luz / se apagó todo, ¿perdí la partida?**
Casi seguro que no: el juego guarda solo cada hora y hay copias diarias fuera de la máquina.
Prendé de nuevo con `./scripts/cloud-start.sh` y fijate.

**10. Me llegó un mail de Oracle avisando del gasto**
Es la alerta que configuraste, funcionando. Si no estás jugando, apagá la máquina con
`./scripts/cloud-stop.sh`, o borrá todo con `make destroy-all`.

Para cualquier otra cosa, corré `make doctor` y abrí un issue con esa salida:
[plantilla "No puedo conectarme"](.github/ISSUE_TEMPLATE/no-puedo-conectarme.yml).

---

## Si querés entender cómo funciona

| Documento | Qué hay adentro |
|---|---|
| [`docs/runbook.md`](docs/runbook.md) | Referencia completa de operación: alta de la cuenta, deploy, backups, wipe, troubleshooting, cómo validar cambios de infraestructura |
| [`PLAN.md`](PLAN.md) | Por qué está hecho así: decisiones, comparación de proveedores y precios, fases |
| [`docs/research/`](docs/research/) | La investigación con fuentes: instalación del server B42, Docker, hosting, configuración y mods |
| [`docs/mods.md`](docs/mods.md) | Todo sobre mods |
| [`CONTRIBUTING.md`](CONTRIBUTING.md) | Cómo mandar un cambio |

En resumen: **OpenTofu** crea la máquina en Oracle Cloud, **cloud-init** la prepara sola en el
primer arranque, **Docker** corre el juego, **systemd** lo levanta y lo apaga limpio, y **cron**
hace las copias de seguridad. La configuración de la partida vive en `config/` y es la única
fuente de verdad.

### Correr el server en tu propia computadora

Si querés probar sin nube (hace falta Docker, ~15 GB de disco y 10 GB de RAM libre):

```bash
make mcrcon      # compila la herramienta de administración
make up          # levanta el server local
make logs        # está listo cuando dice "*** SERVER STARTED ****"
make down        # apagado limpio: NUNCA uses docker stop
```

Tus amigos de la misma casa entran con la IP local de tu computadora (`ip -4 addr`) y el puerto
16261.

---

Licencia [MIT](LICENSE). Project Zomboid es de The Indie Stone; este repo no tiene relación con
ellos.
