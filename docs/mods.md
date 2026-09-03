# Mods

Cómo agregar, quitar y verificar mods del Steam Workshop en este servidor.
Todo lo de acá está verificado empíricamente contra **PZ 42.20.4** (`b0bbce05d5`) el **2026-09-03**,
sobre la imagen `danixu86/project-zomboid-dedicated-server@sha256:a98b0f21…`.

## 1. Fuente de verdad: `config/mods.txt`

Los mods **no** se editan a mano en `servertest.ini`. Se listan en `config/mods.txt`, una línea
por mod, y `scripts/render-config.sh` genera desde ahí las claves `Mods=` y `WorkshopItems=`
del ini renderizado.

```
# <workshop_id>  <mod_id>  # nombre libre
3750253491  VB_CommonSense  # Common Sense [B42.20+]
```

- El **orden del archivo es el load order** (`Mods=` se arma en ese orden).
- Un mismo `workshop_id` puede aparecer en varias líneas si el item del Workshop trae varios
  sub-mods: `WorkshopItems=` los deduplica, `Mods=` los conserva todos.
- Líneas vacías y comentarios (`#`) se ignoran.

## 2. Cómo obtener los dos IDs

| ID | Dónde sale |
|---|---|
| **Workshop ID** (numérico) | El número al final de la URL de la página del mod: `https://steamcommunity.com/sharedfiles/filedetails/?id=3750253491` → `3750253491` |
| **Mod ID** (texto) | El campo `id=` del archivo `mod.info` del mod. La mayoría de las páginas de Workshop lo publican en la descripción ("Mod ID: …"). |

En **Build 42** `mod.info` ya no está en la raíz del mod: está dentro de `common/` o de una carpeta
de versión (`42/`, `42.1/`, …), según cómo lo haya empaquetado el autor. Si el mod ya está
descargado en el server, la forma segura de encontrarlo es buscar:

```bash
find data/workshop/content/108600 -name mod.info -exec grep -H '^id=' {} \;
```

Ejemplo real de este server:

```
data/workshop/content/108600/3750253491/mods/CommonSense/common/mod.info:id=VB_CommonSense
```

(En este caso el autor lo dejó en `common/`; otros mods lo ponen en `42/`. Las dos ubicaciones son
válidas para el engine.)

## 3. Formato en el ini y el prefijo `\` — resultado empírico

```ini
Mods=ModA;ModB
WorkshopItems=111111111;222222222
```

Ambas listas van separadas por `;`. `WorkshopItems=` le dice al server qué bajar del Workshop;
`Mods=` le dice cuáles cargar.

**Sobre el prefijo `\` por Mod ID** (`Mods=\ModA;\ModB`), que la documentación de terceros daba por
obligatorio en B42: se probaron los dos modos en 42.20.4, con arranque completo del server en cada
caso.

| `Mods=` en el ini | Log del server | Resultado |
|---|---|---|
| `Mods=VB_CommonSense` | `LOG : Mod f:0 st:…> loading VB_CommonSense` | **carga** |
| `Mods=\VB_CommonSense` | `LOG : Mod f:0 st:…> loading VB_CommonSense` | **carga igual** |

**Conclusión: en 42.20.4 el prefijo `\` es indiferente.** El engine lo tolera pero no lo necesita.
Este repo usa la forma **sin prefijo** (`MOD_ID_PREFIX=` vacío en `.env`), que es la más legible.

Si en el futuro alguna versión vuelve a exigirlo, no hay que tocar `mods.txt`: alcanza con poner en
`.env`

```sh
MOD_ID_PREFIX="\\"
```

Ojo con la sintaxis: `.env` lo leen **dos** parsers distintos (`source` de bash en los scripts y el
parser propio de `docker compose`). `MOD_ID_PREFIX='\'` hace que `docker compose` falle con
`unterminated quoted value`, y `MOD_ID_PREFIX=\` a secas hace que bash se coma la línea siguiente.
Solo la forma con comillas dobles y doble backslash funciona en los dos.

## 4. Load order

Casi nunca importa. Solo cuando dos mods pisan el mismo archivo o la misma celda de mapa. El orden
efectivo es el de `config/mods.txt`. Para mods de mapa, revisar solapamiento de celdas antes de
combinarlos.

## 5. Procedimiento para agregar un mod

1. Confirmar en la página de Steam Workshop que el mod es **B42 (42.20+)**. Muchos mods tienen
   forks/ports paralelos: el ecosistema quedó fragmentado después del pase de B42 a estable.
2. Anotar Workshop ID y Mod ID.
3. Agregar la línea en `config/mods.txt` (posición = load order).
4. `make restart` — hace `save` + `quit` limpio, re-renderiza el ini y arranca de nuevo.
5. Verificar en los logs que bajó y cargó:

   ```bash
   make logs
   # descarga:
   #   Workshop: item state CheckItemState -> DownloadPending ID=3750253491
   #   Workshop: download 352656/352656 ID=3750253491
   # carga:
   #   LOG  : Mod          f:0 st:…> loading VB_CommonSense
   ```

   Si el ID aparece en `WorkshopItems=` pero nunca hay un `loading <ModID>`, el **Mod ID está mal**
   (no el Workshop ID): el archivo se bajó pero el server no encontró ese `id=` adentro.
6. Los clientes bajan el mod solos al conectarse (necesitan tener el Workshop de Steam habilitado).

## 6. Procedimiento para quitar un mod

1. Borrar (o comentar) la línea en `config/mods.txt`.
2. `make restart`.

**Riesgo**: sacar un mod que ya dejó cosas en el mundo puede romper el save. Es seguro para mods de
UI/QoL puros; es riesgoso para mods de mapa cuyas celdas ya se generaron, y para mods que agregaron
ítems que los jugadores tienen encima. Hacer backup del directorio
`data/zomboid/Saves/Multiplayer/servertest` antes de sacar cualquier mod de contenido.

## 7. Actualizaciones de mods

Los mods del Workshop se re-descargan en cada arranque del server. Si un modder publica una
actualización con el server prendido, los clientes van a tener una versión distinta a la del server
y van a fallar al conectar con error de mismatch. La solución es siempre la misma: `make restart`.

## 8. Notas de operación verificadas

- `SELF_MANAGED_MODS=1` está seteado en `docker-compose.yml`. Sin esa variable el entrypoint de la
  imagen **borra** `Mods=` y `WorkshopItems=` del ini en cada arranque (setea la clave vacía cuando
  `MOD_IDS`/`WORKSHOP_IDS` están vacías). Confirmado en el log:
  `*** INFO: SELF_MANAGED_MODS is set; leaving Mods and WorkshopItems untouched ***`.
- **Mods de mapa**: si algún mod trae `media/maps/<Mapa>`, el entrypoint reescribe la clave `Map=`
  del ini y agrega entradas a `servertest_spawnregions.lua`. Con mods sin mapas (el caso actual) no
  toca ninguno de los dos. Detalle en `docs/research/02-docker-and-tooling.md` §7.2.
- Los mods descargados quedan en `data/workshop/content/108600/<workshop_id>/`. Borrar ese
  directorio fuerza una re-descarga limpia en el próximo arranque.
